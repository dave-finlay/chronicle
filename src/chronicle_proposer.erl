%% @author Couchbase <info@couchbase.com>
%% @copyright 2020 Couchbase, Inc.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%      http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
-module(chronicle_proposer).

-behavior(gen_statem).
-compile(export_all).

-include("chronicle.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-import(chronicle_utils, [get_position/1,
                          get_quorum_peers/1,
                          have_quorum/2,
                          is_quorum_feasible/3,
                          term_number/1]).

-define(SERVER, ?SERVER_NAME(?MODULE)).

%% TODO: move these to the config
-define(STOP_TIMEOUT, 10000).
-define(ESTABLISH_TERM_TIMEOUT, 10000).
-define(CHECK_PEERS_INTERVAL, 5000).

-record(data, { parent,

                peer,

                %% TODO: reconsider what's needed and what's not needed here
                history_id,
                term,
                quorum,
                peers,
                quorum_peers,
                machines,
                config,
                config_revision,
                high_seqno,
                committed_seqno,

                being_removed,

                peer_statuses,
                monitors_peers,
                monitors_refs,

                %% Used only when the state is 'establish_term'.
                %% TODO: consider using different data records for
                %% establish_term and proposing states
                votes,
                failed_votes,
                branch,

                %% Used when the state is 'proposing'.
                pending_entries,
                sync_requests,
                catchup_pid,

                config_change_reply_to,
                postponed_config_requests }).

-record(peer_status, { needs_sync,
                       acked_seqno,
                       acked_commit_seqno,
                       sent_seqno,
                       sent_commit_seqno,

                       catchup_in_progress = false }).

-record(sync_request, { ref,
                        reply_to,
                        votes,
                        failed_votes }).

start_link(HistoryId, Term) ->
    Self = self(),
    gen_statem:start_link(?START_NAME(?MODULE),
                          ?MODULE, [Self, HistoryId, Term], []).

stop(Pid) ->
    gen_statem:call(Pid, stop, ?STOP_TIMEOUT).

sync_quorum(Pid, ReplyTo) ->
    gen_statem:cast(Pid, {sync_quorum, ReplyTo}).

get_config(Pid, ReplyTo) ->
    gen_statem:cast(Pid, {get_config, ReplyTo}).

cas_config(Pid, ReplyTo, NewConfig, Revision) ->
    gen_statem:cast(Pid, {cas_config, ReplyTo, NewConfig, Revision}).

append_commands(Pid, Commands) ->
    gen_statem:cast(Pid, {append_commands, Commands}).

%% gen_statem callbacks
callback_mode() ->
    [handle_event_function, state_enter].

init([Parent, HistoryId, Term]) ->
    chronicle_peers:monitor(),

    PeerStatuses = ets:new(peer_statuses, [protected, set]),
    SyncRequests = ets:new(sync_requests,
                           [protected, set, {keypos, #sync_request.ref}]),
    Data = #data{ parent = Parent,
                  history_id = HistoryId,
                  term = Term,
                  peer_statuses = PeerStatuses,
                  monitors_peers = #{},
                  monitors_refs = #{},
                  %% TODO: store votes, failed_votes and peers as sets
                  votes = [],
                  failed_votes = [],
                  pending_entries = queue:new(),
                  sync_requests = SyncRequests,
                  postponed_config_requests = []},

    {ok, establish_term, Data}.

handle_event(enter, _OldState, NewState, Data) ->
    handle_state_enter(NewState, Data);
handle_event(state_timeout, establish_term_timeout, State, Data) ->
    handle_establish_term_timeout(State, Data);
handle_event(info, check_peers, State, Data) ->
    case State of
        proposing ->
            {keep_state, check_peers(Data)};
        {stopped, _} ->
            keep_state_and_data
    end;
handle_event(info, {{agent_response, Ref, Peer, Request}, Result}, State,
             #data{peers = Peers} = Data) ->
    case lists:member(Peer, Peers) of
        true ->
            case get_peer_monitor(Peer, Data) of
                {ok, OurRef} when OurRef =:= Ref ->
                    handle_agent_response(Peer, Request, Result, State, Data);
                _ ->
                    ?DEBUG("Ignoring a stale response from peer ~p.~n"
                           "Request:~n~p",
                           [Peer, Request]),
                    keep_state_and_data
            end;
        false ->
            ?INFO("Ignoring a response from a removed peer ~p.~n"
                  "Peers:~n~p~n"
                  "Request:~n~p",
                  [Peer, Peers, Request]),
            keep_state_and_data
    end;
handle_event(info, {nodeup, Peer, Info}, State, Data) ->
    handle_nodeup(Peer, Info, State, Data);
handle_event(info, {nodedown, Peer, Info}, State, Data) ->
    handle_nodedown(Peer, Info, State, Data);
handle_event(info, {'DOWN', MRef, process, Pid, Reason}, State, Data) ->
    handle_down(MRef, Pid, Reason, State, Data);
handle_event(cast, {sync_quorum, ReplyTo}, State, Data) ->
    handle_sync_quorum(ReplyTo, State, Data);
handle_event(cast, {get_config, ReplyTo} = Request, proposing, Data) ->
    maybe_postpone_config_request(
      Request, Data,
      fun () ->
              handle_get_config(ReplyTo, Data)
      end);
handle_event(cast, {get_config, ReplyTo}, {stopped, _}, _Data) ->
    reply_not_leader(ReplyTo),
    keep_state_and_data;
handle_event(cast,
             {cas_config, ReplyTo, NewConfig, Revision} = Request,
             proposing, Data) ->
    maybe_postpone_config_request(
      Request, Data,
      fun () ->
              handle_cas_config(ReplyTo, NewConfig, Revision, Data)
      end);
handle_event(cast, {cas_config, ReplyTo, _, _}, {stopped, _}, _Data) ->
    reply_not_leader(ReplyTo),
    keep_state_and_data;
handle_event(cast, {append_commands, Commands}, State, Data) ->
    handle_append_commands(Commands, State, Data);
handle_event({call, From}, stop, State, Data) ->
    handle_stop(From, State, Data);
handle_event({call, From}, _Call, _State, _Data) ->
    {keep_state_and_data, [{reply, From, nack}]};
handle_event(Type, Event, _State, _Data) ->
    ?WARNING("Unexpected event ~p", [{Type, Event}]),
    keep_state_and_data.

%% internal
handle_state_enter(establish_term,
                   #data{history_id = HistoryId, term = Term} = Data) ->
    %% Establish term locally first. This ensures that the metadata we're
    %% going to be using won't change (unless another node starts a higher
    %% term) between when we get it here and when we get a majority of votes.
    case chronicle_agent:establish_local_term(HistoryId, Term) of
        {ok, Metadata} ->
            Quorum = get_establish_quorum(Metadata),
            Peers = get_quorum_peers(Quorum),
            case lists:member(?SELF_PEER, get_quorum_peers(Quorum)) of
                true ->
                    establish_term_init(Metadata, Data);
                false ->
                    ?INFO("Refusing to start a term ~p in history id ~p. "
                          "We're not a voting member anymore.~n"
                          "Peers:~n~p",
                          [Term, HistoryId, Peers]),
                    {stop, {not_voter, Peers}}
            end;
        {error, Error} ->
            ?DEBUG("Error trying to establish local term. Stepping down.~n"
                   "History id: ~p~n"
                   "Term: ~p~n"
                   "Error: ~p",
                   [HistoryId, Term, Error]),
            {stop, {local_establish_term_failed, HistoryId, Term, Error}}
    end;
handle_state_enter(proposing, Data) ->
    NewData0 = start_catchup_process(Data),
    NewData1 = preload_pending_entries(NewData0),
    NewData2 = maybe_resolve_branch(NewData1),
    NewData = maybe_complete_config_transition(NewData2),

    announce_proposer_ready(NewData),

    {keep_state, replicate(check_peers(NewData))};
handle_state_enter({stopped, _}, _Data) ->
    keep_state_and_data.

start_catchup_process(#data{history_id = HistoryId, term = Term} = Data) ->
    case chronicle_catchup:start_link(HistoryId, Term) of
        {ok, Pid} ->
            Data#data{catchup_pid = Pid};
        {error, Error} ->
            exit({failed_to_start_catchup_process, Error})
    end.

stop_catchup_process(#data{catchup_pid = Pid} = Data) ->
    case Pid of
        undefined ->
            Data;
        _ ->
            chronicle_catchup:stop(Pid),
            Data#data{catchup_pid = undefined}
    end.

preload_pending_entries(#data{history_id = HistoryId,
                              term = Term,
                              high_seqno = HighSeqno} = Data) ->
    LocalCommittedSeqno = get_local_committed_seqno(Data),
    case HighSeqno > LocalCommittedSeqno of
        true ->
            case chronicle_agent:get_log(HistoryId, Term,
                                         LocalCommittedSeqno + 1, HighSeqno) of
                {ok, Entries} ->
                    Data#data{pending_entries = queue:from_list(Entries)};
                {error, Error} ->
                    ?WARNING("Encountered an error while fetching "
                             "uncommitted entries from local agent.~n"
                             "History id: ~p~n"
                             "Term: ~p~n"
                             "Committed seqno: ~p~n"
                             "High seqno: ~p~n"
                             "Error: ~p",
                             [HistoryId, Term,
                              LocalCommittedSeqno, HighSeqno, Error]),
                    exit({preload_pending_entries_failed, Error})
            end;
        false ->
            Data
    end.

announce_proposer_ready(#data{parent = Parent,
                              history_id = HistoryId,
                              term = Term,
                              high_seqno = HighSeqno}) ->
    chronicle_server:proposer_ready(Parent, HistoryId, Term, HighSeqno).

establish_term_init(Metadata,
                    #data{history_id = HistoryId, term = Term} = Data) ->
    Self = Metadata#metadata.peer,
    Quorum = require_self_quorum(get_establish_quorum(Metadata)),
    Peers = get_quorum_peers(Quorum),
    LivePeers = get_live_peers(Peers),
    DeadPeers = Peers -- LivePeers,

    ?DEBUG("Going to establish term ~p (history id ~p).~n"
           "Metadata:~n~p~n"
           "Live peers:~n~p",
           [Term, HistoryId, Metadata, LivePeers]),

    #metadata{config = Config,
              config_revision = ConfigRevision,
              high_seqno = HighSeqno,
              committed_seqno = CommittedSeqno,
              pending_branch = PendingBranch} = Metadata,

    case is_quorum_feasible(Peers, DeadPeers, Quorum) of
        true ->
            OtherPeers = LivePeers -- [?SELF_PEER],

            %% Send a fake response to update our state with the
            %% knowledge that we've established the term
            %% locally. Initally, I wasn't planning to use such
            %% somewhat questionable approach and instead would update
            %% the state here. But if our local peer is the only peer,
            %% then we need to transition to propsing state
            %% immediately. But brain-dead gen_statem won't let you
            %% transition to a different state from a state_enter
            %% callback. So here we are.
            NewData0 = send_local_establish_term(Metadata, Data),
            NewData1 =
                send_establish_term(OtherPeers, Metadata, NewData0),
            NewData = NewData1#data{peer = Self,
                                    peers = Peers,
                                    quorum_peers = Peers,
                                    quorum = Quorum,
                                    machines = config_machines(Config),
                                    votes = [],
                                    failed_votes = DeadPeers,
                                    config = Config,
                                    config_revision = ConfigRevision,
                                    high_seqno = HighSeqno,
                                    committed_seqno = CommittedSeqno,
                                    branch = PendingBranch,
                                    being_removed = false},
            {keep_state,
             NewData,
             {state_timeout,
              ?ESTABLISH_TERM_TIMEOUT, establish_term_timeout}};
        false ->
            %% This should be a rare situation. That's because to be
            %% elected a leader we need to get a quorum of votes. So
            %% at least a quorum of nodes should be alive.
            ?WARNING("Can't establish term ~p, history id ~p.~n"
                     "Not enough peers are alive to achieve quorum.~n"
                     "Peers: ~p~n"
                     "Live peers: ~p~n"
                     "Quorum: ~p",
                     [Term, HistoryId, Peers, LivePeers, Quorum]),
            {stop, {error, no_quorum}}
    end.

handle_establish_term_timeout(establish_term = _State, #data{term = Term}) ->
    ?ERROR("Failed to establish term ~p after ~bms",
           [Term, ?ESTABLISH_TERM_TIMEOUT]),
    {stop, establish_term_timeout}.

check_peers(#data{peers = Peers} = Data) ->
    LivePeers = get_live_peers(Peers),
    PeersToCheck =
        lists:filter(
          fun (Peer) ->
                  case get_peer_status(Peer, Data) of
                      {ok, _} ->
                          false;
                      not_found ->
                          true
                  end
          end, LivePeers),

    erlang:send_after(?CHECK_PEERS_INTERVAL, self(), check_peers),
    send_request_position(PeersToCheck, Data).

handle_agent_response(Peer,
                      {establish_term, _, _, _} = Request,
                      Result, State, Data) ->
    handle_establish_term_result(Peer, Request, Result, State, Data);
handle_agent_response(Peer,
                      {append, _, _, _, _} = Request,
                      Result, State, Data) ->
    handle_append_result(Peer, Request, Result, State, Data);
handle_agent_response(Peer, peer_position, Result, State, Data) ->
    handle_peer_position_result(Peer, Result, State, Data);
handle_agent_response(Peer,
                      {sync_quorum, _} = Request,
                      Result, State, Data) ->
    handle_sync_quorum_result(Peer, Request, Result, State, Data);
handle_agent_response(Peer, catchup, Result, State, Data) ->
    handle_catchup_result(Peer, Result, State, Data).

handle_establish_term_result(Peer,
                             {establish_term, HistoryId, Term, Position},
                             Result, State, Data) ->
    true = (HistoryId =:= Data#data.history_id),
    true = (Term =:= Data#data.term),

    case Result of
        {ok, #metadata{committed_seqno = CommittedSeqno} = Metadata} ->
            init_peer_status(Peer, Metadata, Data),
            establish_term_handle_vote(Peer, {ok, CommittedSeqno}, State, Data);
        {error, Error} ->
            remove_peer_status(Peer, Data),
            case handle_common_error(Peer, Error, Data) of
                {stop, Reason} ->
                    stop(Reason, State, Data);
                ignored ->
                    ?WARNING("Failed to establish "
                             "term ~p (history id ~p, log position ~p) "
                             "on peer ~p: ~p",
                             [Term, HistoryId, Position, Peer, Error]),

                    case Error of
                        {behind, _} ->
                            %% We keep going despite the fact we're behind
                            %% this peer because we still might be able to get
                            %% a majority of votes.
                            establish_term_handle_vote(Peer,
                                                       failed, State, Data);
                        {conflicting_term, _} ->
                            %% Some conflicting_term errors are ignored by
                            %% handle_common_error. If we hit one, we record a
                            %% failed vote, but keep going.
                            establish_term_handle_vote(Peer,
                                                       failed, State, Data);
                        _ ->
                            stop({unexpected_error, Peer, Error}, State, Data)
                    end
            end
    end.

handle_common_error(Peer, Error,
                    #data{history_id = HistoryId, term = Term}) ->
    case Error of
        {conflicting_term, OtherTerm} ->
            OurTermNumber = term_number(Term),
            OtherTermNumber = term_number(OtherTerm),

            case OtherTermNumber > OurTermNumber of
                true ->
                    ?INFO("Conflicting term on peer ~p. Stopping.~n"
                          "History id: ~p~n"
                          "Our term: ~p~n"
                          "Conflicting term: ~p",
                          [Peer, HistoryId, Term, OtherTerm]),
                    {stop, {conflicting_term, Term, OtherTerm}};
                false ->
                    %% This is most likely to happen when two different nodes
                    %% try to start a term of the same number at around the
                    %% same time. If one of the nodes manages to establish the
                    %% term on a quorum of nodes, despite conflicts, it'll be
                    %% able propose and replicate just fine. So we ignore such
                    %% conflicts.
                    true = (OurTermNumber =:= OtherTermNumber),
                    ?INFO("Conflicting term on peer ~p. Ignoring.~n"
                          "History id: ~p~n"
                          "Our term: ~p~n"
                          "Conflicting term: ~p~n",
                          [Peer, HistoryId, Term, OtherTerm]),

                    ignored
            end;
        {history_mismatch, OtherHistoryId} ->
            ?INFO("Saw history mismatch when trying on peer ~p.~n"
                  "Our history id: ~p~n"
                  "Conflicting history id: ~p",
                  [Peer, HistoryId, OtherHistoryId]),

            %% The system has undergone a partition. Either we are part of the
            %% new partition but haven't received the corresponding branch
            %% record yet. Or alternatively, we've been partitioned out. In
            %% the latter case we, probably, shouldn't continue to operate.
            %%
            %% TODO: handle the latter case better
            {stop, {history_mismatch, HistoryId, OtherHistoryId}};
        _ ->
            ignored
    end.

establish_term_handle_vote(Peer, Status, proposing, Data) ->
    case Status of
        {ok, _} ->
            {keep_state, replicate(Data)};
        failed ->
            %% This is not exactly clean. But the intention is the
            %% following. We got some error that we chose to ignore. But since
            %% we are already proposing, we need to know this peer's
            %% position. And that's what it does.
            {keep_state, check_peers(demonitor_agents([Peer], Data))}
    end;
establish_term_handle_vote(Peer, Status, establish_term = State,
                           #data{high_seqno = HighSeqno,
                                 committed_seqno = OurCommittedSeqno,
                                 votes = Votes,
                                 failed_votes = FailedVotes} = Data) ->
    NewData =
        case Status of
            {ok, CommittedSeqno} ->
                NewCommittedSeqno = max(OurCommittedSeqno, CommittedSeqno),
                case NewCommittedSeqno =/= OurCommittedSeqno of
                    true ->
                        true = (HighSeqno >= NewCommittedSeqno),
                        ?INFO("Discovered new committed seqno from peer ~p.~n"
                              "Old committed seqno: ~p~n"
                              "New committed seqno: ~p",
                              [Peer, OurCommittedSeqno, NewCommittedSeqno]);
                    false ->
                        ok
                end,

                Data#data{votes = [Peer | Votes],
                          committed_seqno = NewCommittedSeqno};
            failed ->
                %% Demonitor the peer so we recheck on it once and if we
                %% successfully establish the term.
                %%
                %% TODO: consider replacing it with something cleaner
                demonitor_agents([Peer],
                                 Data#data{failed_votes = [Peer | FailedVotes]})
        end,

    establish_term_maybe_transition(State, NewData).

establish_term_maybe_transition(establish_term = State,
                                #data{term = Term,
                                      history_id = HistoryId,
                                      quorum_peers = Peers,
                                      votes = Votes,
                                      failed_votes = FailedVotes,
                                      quorum = Quorum} = Data) ->
    case have_quorum(Votes, Quorum) of
        true ->
            ?DEBUG("Established term ~p (history id ~p) successfully.~n"
                   "Votes: ~p~n",
                   [Term, HistoryId, Votes]),

            {next_state, proposing, Data};
        false ->
            case is_quorum_feasible(Peers, FailedVotes, Quorum) of
                true ->
                    {keep_state, Data};
                false ->
                    ?WARNING("Couldn't establish term ~p, history id ~p.~n"
                             "Votes received: ~p~n"
                             "Quorum: ~p~n",
                             [Term, HistoryId, Votes, Quorum]),
                    stop({error, no_quorum}, State, Data)
            end
    end.

maybe_resolve_branch(#data{branch = undefined} = Data) ->
    Data;
maybe_resolve_branch(#data{high_seqno = HighSeqno,
                           committed_seqno = CommittedSeqno,
                           branch = Branch,
                           config = Config,
                           pending_entries = PendingEntries} = Data) ->
    %% Some of the pending entries may actually be committed, but our local
    %% agent doesn't know yet. So those need to be preserved.
    NewPendingEntries =
        chronicle_utils:queue_takewhile(
          fun (#log_entry{seqno = Seqno}) ->
                  Seqno =< CommittedSeqno
          end, PendingEntries),
    NewData = Data#data{branch = undefined,
                        %% Note, that this essintially truncates any
                        %% uncommitted entries. This is acceptable/safe to do
                        %% for the following reasons:
                        %%
                        %%  1. We are going through a quorum failover, so data
                        %%  inconsistencies are expected.
                        %%
                        %%  2. Since a unanimous quorum is required for
                        %%  resolving quorum failovers, the leader is
                        %%  guaranteed to know the highest committed seqno
                        %%  observed by the surviving part of the cluster. In
                        %%  other words, we won't truncate something that was
                        %%  known to have been committed.
                        high_seqno = CommittedSeqno,
                        pending_entries = NewPendingEntries},

    %% Note, that the new config may be based on an uncommitted config that
    %% will get truncated from the history. This can be confusing and it's
    %% possible to deal with this situation better. But for the time being I
    %% decided not to bother.
    NewConfig = Config#config{voters = Branch#branch.peers},

    ?INFO("Resolving a branch.~n"
          "High seqno: ~p~n"
          "Committed seqno: ~p~n"
          "Branch:~n~p~n"
          "Latest known config:~n~p~n"
          "New config:~n~p",
          [HighSeqno, CommittedSeqno, Branch, Config, NewConfig]),

    force_propose_config(NewConfig, NewData).

handle_append_result(Peer, Request, Result, proposing = State, Data) ->
    {append, HistoryId, Term, CommittedSeqno, HighSeqno} = Request,

    true = (HistoryId =:= Data#data.history_id),
    true = (Term =:= Data#data.term),

    case Result of
        ok ->
            NewData = maybe_drop_pending_entries(Peer, CommittedSeqno, Data),
            handle_append_ok(Peer, HighSeqno, CommittedSeqno, State, NewData);
        {error, Error} ->
            handle_append_error(Peer, Error, State, Data)
    end.

maybe_drop_pending_entries(Peer, NewCommittedSeqno, Data)
  when Peer =:= ?SELF_PEER ->
    OldCommittedSeqno = get_local_committed_seqno(Data),
    case OldCommittedSeqno =:= NewCommittedSeqno of
        true ->
            Data;
        false ->
            PendingEntries = Data#data.pending_entries,
            NewPendingEntries =
                chronicle_utils:queue_dropwhile(
                  fun (Entry) ->
                          Entry#log_entry.seqno =< NewCommittedSeqno
                  end, PendingEntries),

            Data#data{pending_entries = NewPendingEntries}
    end;
maybe_drop_pending_entries(_, _, Data) ->
    Data.

handle_append_error(Peer, Error, proposing = State, Data) ->
    case handle_common_error(Peer, Error, Data) of
        {stop, Reason} ->
            stop(Reason, State, Data);
        ignored ->
            ?WARNING("Append failed on peer ~p: ~p", [Peer, Error]),
            stop({unexpected_error, Peer, Error}, State, Data)
    end.

handle_append_ok(Peer, PeerHighSeqno, PeerCommittedSeqno,
                 proposing = State,
                 #data{committed_seqno = CommittedSeqno} = Data) ->
    ?DEBUG("Append ok on peer ~p.~n"
           "High Seqno: ~p~n"
           "Committed Seqno: ~p",
           [Peer, PeerHighSeqno, PeerCommittedSeqno]),
    set_peer_acked_seqnos(Peer, PeerHighSeqno, PeerCommittedSeqno, Data),

    case deduce_committed_seqno(Data) of
        {ok, NewCommittedSeqno}
          when NewCommittedSeqno > CommittedSeqno ->
            ?DEBUG("Committed seqno advanced.~n"
                   "New committed seqno: ~p~n"
                   "Old committed seqno: ~p",
                   [NewCommittedSeqno, CommittedSeqno]),
            NewData0 = Data#data{committed_seqno = NewCommittedSeqno},

            case handle_config_post_append(Data, NewData0) of
                {ok, NewData, Effects} ->
                    {keep_state, replicate(NewData), Effects};
                {stop, Reason, NewData} ->
                    stop(Reason, State, NewData)
            end;
        {ok, _NewCommittedSeqno} ->
            %% Note, that it's possible for the deduced committed seqno to go
            %% backwards with respect to our own committed seqno here. This
            %% may happen for multiple reasons. The simplest scenario is where
            %% some nodes go down at which point their peer statuses are
            %% erased. If the previous committed seqno was acknowledged only
            %% by a minimal majority of nodes, any of them going down will
            %% result in the deduced seqno going backwards.
            {keep_state, Data};
        no_quorum ->
            %% This case is possible because deduce_committed_seqno/1 always
            %% uses the most up-to-date config. So what was committed in the
            %% old config, might not yet have a quorum in the current
            %% configuration.
            {keep_state, Data}
    end.

handle_peer_position_result(Peer, Result, proposing = State, Data) ->
    ?DEBUG("Peer position response from ~p:~n~p", [Peer, Result]),

    case Result of
        {ok, Metadata} ->
            init_peer_status(Peer, Metadata, Data),
            {keep_state, replicate(Data)};
        {error, Error} ->
            {stop, Reason} = handle_common_error(Peer, Error, Data),
            stop(Reason, State, Data)
    end.

handle_sync_quorum_result(Peer, {sync_quorum, Ref}, Result,
                          proposing = State,
                          #data{sync_requests = SyncRequests} = Data) ->
    ?DEBUG("Sync quorum response from ~p: ~p", [Peer, Result]),
    case ets:lookup(SyncRequests, Ref) of
        [] ->
            keep_state_and_data;
        [#sync_request{} = Request] ->
            case Result of
                {ok, _} ->
                    sync_quorum_handle_vote(Peer, ok, Request, Data),
                    keep_state_and_data;
                {error, Error} ->
                    case handle_common_error(Peer, Error, Data) of
                        {stop, Reason} ->
                            stop(Reason, State, Data);
                        ignored ->
                            ?ERROR("Unexpected error in sync quorum: ~p",
                                   [Error]),
                            sync_quorum_handle_vote(Peer,
                                                    failed, Request, Data),
                            keep_state_and_data
                    end
            end
    end.

sync_quorum_handle_vote(Peer, Status,
                        #sync_request{ref = Ref,
                                      votes = Votes,
                                      failed_votes = FailedVotes} = Request,
                        #data{sync_requests = Requests} = Data) ->
    NewRequest =
        case Status of
            ok ->
                Request#sync_request{votes = [Peer | Votes]};
            failed ->
                Request#sync_request{failed_votes = [Peer | FailedVotes]}
        end,

    case sync_quorum_maybe_reply(NewRequest, Data) of
        continue ->
            ets:insert(Requests, NewRequest);
        done ->
            ets:delete(Requests, Ref)
    end.

sync_quorum_maybe_reply(Request, Data) ->
    case sync_quorum_check_result(Request, Data) of
        continue ->
            continue;
        Result ->
            reply_request(Request#sync_request.reply_to, Result),
            done
    end.

sync_quorum_check_result(#sync_request{votes = Votes,
                                       failed_votes = FailedVotes},
                         #data{quorum = Quorum, quorum_peers = Peers}) ->
    case have_quorum(Votes, Quorum) of
        true ->
            ok;
        false ->
            case is_quorum_feasible(Peers, FailedVotes, Quorum) of
                true ->
                    continue;
                false ->
                    {error, no_quorum}
            end
    end.

sync_quorum_handle_peer_down(Peer, #data{sync_requests = Tab} = Data) ->
    lists:foreach(
      fun (#sync_request{votes = Votes,
                         failed_votes = FailedVotes} = Request) ->
              HasVoted = lists:member(Peer, Votes)
                  orelse lists:member(Peer, FailedVotes),

              case HasVoted of
                  true ->
                      ok;
                  false ->
                      sync_quorum_handle_vote(Peer, failed, Request, Data)
              end
      end, ets:tab2list(Tab)).

sync_quorum_on_config_update(AddedPeers, #data{sync_requests = Tab} = Data) ->
    lists:foldl(
      fun (#sync_request{ref = Ref} = Request, AccData) ->
              %% We might have a quorum in the new configuration. If that's
              %% the case, reply to the request immediately.
              case sync_quorum_maybe_reply(Request, AccData) of
                  done ->
                      ets:delete(Tab, Ref),
                      AccData;
                  continue ->
                      %% If there are new peers, we need to send extra
                      %% ensure_term requests to them. Otherwise, we might not
                      %% ever get enough responses to reach quorum.
                      send_ensure_term(AddedPeers, {sync_quorum, Ref}, AccData)
              end
      end, Data, ets:tab2list(Tab)).

sync_quorum_reply_not_leader(#data{sync_requests = Tab}) ->
    lists:foreach(
      fun (#sync_request{ref = Ref, reply_to = ReplyTo}) ->
              reply_not_leader(ReplyTo),
              ets:delete(Tab, Ref)
      end, ets:tab2list(Tab)).

handle_catchup_result(Peer, Result, proposing = State, Data) ->
    case Result of
        {ok, Metadata} ->
            set_peer_status(Peer, Metadata, Data),
            {keep_state, replicate(Data)};
        {error, Error} ->
            case handle_common_error(Peer, Error, Data) of
                {stop, Reason} ->
                    stop(Reason, State, Data);
                ignored ->
                    ?ERROR("Catchup to peer ~p failed with error: ~p",
                           [Peer, Error]),
                    remove_peer_status(Peer, Data),
                    %% TODO: get rid of this
                    %%
                    %% retry immediately so unit tests don't fail
                    {keep_state, check_peers(Data)}
            end
    end.

maybe_complete_config_transition(#data{config = Config} = Data) ->
    case Config of
        #config{} ->
            Data;
        #transition{future_config = FutureConfig} ->
            case is_config_committed(Data) of
                true ->
                    %% Preserve config_change_from if any.
                    ReplyTo = Data#data.config_change_reply_to,
                    propose_config(FutureConfig, ReplyTo, Data);
                false ->
                    Data
            end
    end.

maybe_reply_config_change(#data{config = Config,
                                config_change_reply_to = ReplyTo} = Data) ->
    case Config of
        #config{} ->
            case ReplyTo =/= undefined of
                true ->
                    true = is_config_committed(Data),
                    Revision = Data#data.config_revision,
                    reply_request(ReplyTo, {ok, Revision}),
                    Data#data{config_change_reply_to = undefined};
                false ->
                    Data
            end;
        #transition{} ->
            %% We only reply once the stable config gets committed.
            Data
    end.

maybe_postpone_config_request(Request, Data, Fun) ->
    case is_config_committed(Data) of
        true ->
            Fun();
        false ->
            #data{postponed_config_requests = Postponed} = Data,
            NewPostponed = [{cast, Request} | Postponed],
            {keep_state, Data#data{postponed_config_requests = NewPostponed}}
    end.

unpostpone_config_requests(#data{postponed_config_requests =
                                     Postponed} = Data) ->
    NewData = Data#data{postponed_config_requests = []},
    Effects = [{next_event, Type, Request} ||
                  {Type, Request} <- lists:reverse(Postponed)],
    {NewData, Effects}.

check_leader_got_removed(#data{being_removed = BeingRemoved} = Data) ->
    BeingRemoved andalso is_config_committed(Data).

handle_config_post_append(OldData,
                          #data{peer = Peer,
                                config_revision = ConfigRevision} = NewData) ->
    GotCommitted =
        not is_revision_committed(ConfigRevision, OldData)
        andalso is_revision_committed(ConfigRevision, NewData),

    case GotCommitted of
        true ->
            %% Stop replicating to nodes that might have been removed.
            QuorumNodes = NewData#data.quorum_peers,
            NewData0 = update_peers(QuorumNodes, NewData),
            NewData1 = maybe_reply_config_change(NewData0),
            NewData2 = maybe_complete_config_transition(NewData1),

            case check_leader_got_removed(NewData2) of
                true ->
                    ?INFO("Shutting down because leader ~p "
                          "got removed from peers.~n"
                          "Peers: ~p",
                          [Peer, NewData2#data.quorum_peers]),
                    {stop, leader_removed, NewData2};
                false ->
                    %% Deliver postponed config changes again. We've postponed
                    %% them all the way till this moment to be able to return
                    %% an error that includes the revision of the conflicting
                    %% config. That way the caller can wait to receive the
                    %% conflicting config before retrying.
                    {NewData3, Effects} = unpostpone_config_requests(NewData2),
                    {ok, NewData3, Effects}
            end;
        false ->
            %% Nothing changed, so nothing to do.
            {ok, NewData, []}
    end.

is_config_committed(#data{config_revision = ConfigRevision} = Data) ->
    is_revision_committed(ConfigRevision, Data).

is_revision_committed({_, _, Seqno}, #data{committed_seqno = CommittedSeqno}) ->
    Seqno =< CommittedSeqno.

replicate(Data) ->
    #data{committed_seqno = CommittedSeqno, high_seqno = HighSeqno} = Data,

    case get_peers_to_replicate(HighSeqno, CommittedSeqno, Data) of
        [] ->
            Data;
        Peers ->
            replicate_to_peers(Peers, Data)
    end.

get_peers_to_replicate(HighSeqno, CommitSeqno, #data{peers = Peers} = Data) ->
    LivePeers = get_live_peers(Peers),

    lists:filtermap(
      fun (Peer) ->
              case get_peer_status(Peer, Data) of
                  {ok, #peer_status{needs_sync = NeedsSync,
                                    sent_seqno = PeerSentSeqno,
                                    sent_commit_seqno = PeerSentCommitSeqno,
                                    catchup_in_progress = false}} ->
                      DoSync =
                          NeedsSync
                          orelse HighSeqno > PeerSentSeqno
                          orelse CommitSeqno > PeerSentCommitSeqno,

                      case DoSync of
                          true ->
                              {true, {Peer, PeerSentSeqno}};
                          false ->
                              false
                      end;
                  _ ->
                      false
              end
      end, LivePeers).

config_machines(#config{state_machines = Machines}) ->
    maps:keys(Machines);
config_machines(#transition{future_config = FutureConfig}) ->
    config_machines(FutureConfig).

handle_nodeup(Peer, _Info, State, #data{peers = Peers} = Data) ->
    ?INFO("Peer ~p came up", [Peer]),
    case State of
        establish_term ->
            %% Note, no attempt is made to send establish_term requests to
            %% peers that come up while we're in establish_term state. The
            %% motivation is as follows:
            %%
            %%  1. We go through this state only once right after an election,
            %%  so normally there should be a quorum of peers available anyway.
            %%
            %%  2. Since peers can flip back and forth, it's possible that
            %%  we've already sent an establish_term request to this peer and
            %%  we'll get an error when we try to do this again.
            %%
            %%  3. In the worst case, we won't be able to establish the
            %%  term. This will trigger another election and once and if we're
            %%  elected again, we'll retry with a new set of live peers.
            keep_state_and_data;
        {stopped, _} ->
            keep_state_and_data;
        proposing ->
            case lists:member(Peer, Peers) of
                true ->
                    case get_peer_status(Peer, Data) of
                        {ok, _} ->
                            %% We are already in contact with the peer
                            %% (likely, check_peers initiated the connection
                            %% and that's why we got this message). Nothing
                            %% needs to be done.
                            keep_state_and_data;
                        not_found ->
                            {keep_state,
                             send_request_peer_position(Peer, Data)}
                    end;
                false ->
                    ?INFO("Peer ~p is not in peers:~n~p", [Peer, Peers]),
                    keep_state_and_data
            end
    end.

handle_nodedown(Peer, Info, _State, _Data) ->
    %% If there was an outstanding request, we'll also receive a DOWN message
    %% and handle everything there. Otherwise, we don't care.
    ?INFO("Peer ~p went down: ~p", [Peer, Info]),
    keep_state_and_data.

handle_down(MRef, Pid, Reason, State, Data) ->
    {ok, Peer, NewData} = take_monitor(MRef, Data),
    ?INFO("Observed agent ~p on peer ~p "
          "go down with reason ~p", [Pid, Peer, Reason]),

    case Peer =:= ?SELF_PEER of
        true ->
            ?ERROR("Terminating proposer because local "
                   "agent ~p terminated with reason ~p",
                   [Pid, Reason]),
            stop({agent_terminated, Reason}, State, Data);
        false ->
            maybe_cancel_peer_catchup(Peer, NewData),
            remove_peer_status(Peer, NewData),

            case State of
                establish_term ->
                    establish_term_handle_vote(Peer, failed, State, NewData);
                proposing ->
                    {keep_state, NewData}
            end
    end.

handle_append_commands(Commands, {stopped, _}, _Data) ->
    %% Proposer has stopped. Reject any incoming commands.
    reply_commands_not_leader(Commands),
    keep_state_and_data;
handle_append_commands(Commands, proposing, #data{being_removed = true}) ->
    %% Node is being removed. Don't accept new commands.
    reply_commands_not_leader(Commands),
    keep_state_and_data;
handle_append_commands(Commands,
                       proposing,
                       #data{high_seqno = HighSeqno,
                             pending_entries = PendingEntries} = Data) ->
    {NewHighSeqno, NewPendingEntries, NewData0} =
        lists:foldl(
          fun ({ReplyTo, Command}, {PrevSeqno, AccEntries, AccData} = Acc) ->
                  Seqno = PrevSeqno + 1,
                  case handle_command(Command, Seqno, AccData) of
                      {ok, LogEntry, NewAccData} ->
                          reply_request(ReplyTo, {accepted, Seqno}),
                          {Seqno, queue:in(LogEntry, AccEntries), NewAccData};
                      {reject, Error} ->
                          reply_request(ReplyTo, Error),
                          Acc
                  end
          end,
          {HighSeqno, PendingEntries, Data}, Commands),

    NewData1 = NewData0#data{pending_entries = NewPendingEntries,
                             high_seqno = NewHighSeqno},

    {keep_state, replicate(NewData1)}.

handle_command({rsm_command, RSMName, Command}, Seqno,
               #data{machines = Machines} = Data) ->
    case lists:member(RSMName, Machines) of
        true ->
            RSMCommand = #rsm_command{rsm_name = RSMName,
                                      command = Command},
            {ok, make_log_entry(Seqno, RSMCommand, Data), Data};
        false ->
            ?WARNING("Received a command "
                     "referencing a non-existing RSM: ~p", [RSMName]),
            {reject, {error, {unknown_rsm, RSMName}}}
    end.

reply_commands_not_leader(Commands) ->
    {ReplyTos, _} = lists:unzip(Commands),
    lists:foreach(fun reply_not_leader/1, ReplyTos).

handle_sync_quorum(ReplyTo, {stopped, _}, _Data) ->
    reply_not_leader(ReplyTo),
    keep_state_and_data;
handle_sync_quorum(ReplyTo, proposing,
                   #data{quorum_peers = Peers,
                         sync_requests = SyncRequests} = Data) ->
    %% TODO: timeouts
    LivePeers = get_live_peers(Peers),
    DeadPeers = Peers -- LivePeers,

    Ref = make_ref(),
    Request = #sync_request{ref = Ref,
                            reply_to = ReplyTo,
                            votes = [],
                            failed_votes = DeadPeers},
    case sync_quorum_maybe_reply(Request, Data) of
        continue ->
            ets:insert_new(SyncRequests, Request),
            {keep_state, send_ensure_term(LivePeers, {sync_quorum, Ref}, Data)};
        done ->
            keep_state_and_data
    end.

%% TODO: make the value returned fully linearizable?
handle_get_config(ReplyTo, #data{config = Config,
                                 config_revision = Revision} = Data) ->
    true = is_config_committed(Data),
    #config{} = Config,
    reply_request(ReplyTo, {ok, Config, Revision}),
    keep_state_and_data.

handle_cas_config(ReplyTo, NewConfig, CasRevision,
                  #data{config = Config,
                        config_revision = ConfigRevision} = Data) ->
    %% TODO: this protects against the client proposing transition. But in
    %% reality, it should be solved in some other way
    #config{} = NewConfig,
    #config{} = Config,
    case CasRevision =:= ConfigRevision of
        true ->
            %% TODO: need to backfill new nodes
            Transition = #transition{current_config = Config,
                                     future_config = NewConfig},
            NewData = propose_config(Transition, ReplyTo, Data),
            {keep_state, replicate(NewData)};
        false ->
            Reply = {error, {cas_failed, ConfigRevision}},
            reply_request(ReplyTo, Reply),
            keep_state_and_data
    end.

handle_stop(From, State,
            #data{history_id = HistoryId, term = Term} = Data) ->
    ?INFO("Proposer for term ~p "
          "in history ~p is terminating.", [Term, HistoryId]),
    case State of
        {stopped, Reason} ->
            {stop_and_reply,
             {shutdown, Reason},
             {reply, From, ok}};
        _ ->
            stop(stop, [postpone], State, Data)
    end.

make_log_entry(Seqno, Value, #data{history_id = HistoryId, term = Term}) ->
    #log_entry{history_id = HistoryId,
               term = Term,
               seqno = Seqno,
               value = Value}.

update_config(Config, Revision, #data{quorum_peers = OldQuorumPeers} = Data) ->
    RawQuorum = get_append_quorum(Config, Data),
    BeingRemoved = not lists:member(?SELF_PEER, get_quorum_peers(RawQuorum)),

    %% Always require include local to acknowledge writes, even if the node is
    %% being removed.
    Quorum = require_self_quorum(RawQuorum),
    QuorumPeers = get_quorum_peers(Quorum),

    NewData = Data#data{config = Config,
                        config_revision = Revision,
                        being_removed = BeingRemoved,
                        quorum = Quorum,
                        quorum_peers = QuorumPeers,
                        machines = config_machines(Config)},

    %% When nodes are being removed, attempt to notify them about the new
    %% config that removes them. This is just a best-effort approach. If nodes
    %% are down -- they are not going to get notified.
    NewPeers = lists:usort(OldQuorumPeers ++ QuorumPeers),
    update_peers(NewPeers, NewData).

update_peers(NewPeers, #data{peers = OldPeers,
                             quorum_peers = QuorumPeers} = Data) ->
    [] = (QuorumPeers -- NewPeers),

    RemovedPeers = OldPeers -- NewPeers,
    AddedPeers = NewPeers -- OldPeers,

    NewData = Data#data{peers = NewPeers},
    handle_added_peers(AddedPeers, handle_removed_peers(RemovedPeers, NewData)).

handle_removed_peers(Peers, Data) ->
    remove_peer_statuses(Peers, Data),
    demonitor_agents(Peers, Data).

handle_added_peers(Peers, Data) ->
    NewData = check_peers(Data),
    sync_quorum_on_config_update(Peers, NewData).

log_entry_revision(#log_entry{history_id = HistoryId,
                              term = Term, seqno = Seqno}) ->
    {HistoryId, Term, Seqno}.

force_propose_config(Config, #data{config_change_reply_to =
                                       undefined} = Data) ->
    %% This function doesn't check that the current config is committed, which
    %% should be the case for regular config transitions. It's only meant to
    %% be used after resolving a branch.
    do_propose_config(Config, undefined, Data).

propose_config(Config, ReplyTo, Data) ->
    true = is_config_committed(Data),
    do_propose_config(Config, ReplyTo, Data).

%% TODO: right now when this function is called we replicate the proposal in
%% its own batch. But it can be coalesced with user batches.
do_propose_config(Config, ReplyTo, #data{high_seqno = HighSeqno,
                                         pending_entries = Entries} = Data) ->
    Seqno = HighSeqno + 1,
    LogEntry = make_log_entry(Seqno, Config, Data),
    Revision = log_entry_revision(LogEntry),

    NewEntries = queue:in(LogEntry, Entries),
    NewData = Data#data{pending_entries = NewEntries,
                        high_seqno = Seqno,
                        config_change_reply_to = ReplyTo},
    update_config(Config, Revision, NewData).

get_peer_status(Peer, #data{peer_statuses = Tab}) ->
    case ets:lookup(Tab, Peer) of
        [{_, PeerStatus}] ->
            {ok, PeerStatus};
        [] ->
            not_found
    end.

update_peer_status(Peer, Fun, #data{peer_statuses = Tab} = Data) ->
    {ok, PeerStatus} = get_peer_status(Peer, Data),
    ets:insert(Tab, {Peer, Fun(PeerStatus)}).

mark_status_requested(Peers, #data{peer_statuses = Tab}) ->
    true = ets:insert_new(Tab, [{Peer, requested} || Peer <- Peers]).

init_peer_status(Peer, Metadata, Data) ->
    %% We should never overwrite an existing peer status.
    {ok, requested} = get_peer_status(Peer, Data),
    set_peer_status(Peer, Metadata, Data).

set_peer_status(Peer, Metadata, #data{term = OurTerm, peer_statuses = Tab}) ->
    #metadata{term_voted = PeerTermVoted,
              committed_seqno = PeerCommittedSeqno,
              high_seqno = PeerHighSeqno} = Metadata,

    {CommittedSeqno, HighSeqno, NeedsSync} =
        case PeerTermVoted =:= OurTerm of
            true ->
                %% We've lost communication with the peer. But it's already
                %% voted in our current term, so our histories are compatible.
                {PeerCommittedSeqno, PeerHighSeqno, false};
            false ->
                %% Peer has some uncommitted entries that need to be
                %% truncated. Normally, that'll just happen in the course of
                %% normal replication, but if there are no mutations to
                %% replicate, we need to force replicate to the node.
                DoSync = PeerHighSeqno > PeerCommittedSeqno,


                %% The peer hasn't voted in our term yet, so it may have
                %% divergent entries in the log that need to be truncated.
                %%
                %% TODO: We set all seqno-s to peer's committed seqno. That is
                %% because entries past peer's committed seqno may come from
                %% an alternative, never-to-be-committed history. Using
                %% committed seqno is always safe, but that also means that we
                %% might need to needlessly resend some of the entries that
                %% the peer already has.
                %%
                %% Somewhat peculiarly, the same logic also applies to our
                %% local agent. This all can be addressed by including more
                %% information into establish_term() response and append()
                %% call. But I'll leave for later.
                {PeerCommittedSeqno, PeerCommittedSeqno, DoSync}
        end,

    PeerStatus = #peer_status{needs_sync = NeedsSync,
                              acked_seqno = HighSeqno,
                              sent_seqno = HighSeqno,
                              acked_commit_seqno = CommittedSeqno,
                              sent_commit_seqno = CommittedSeqno},
    ets:insert(Tab, {Peer, PeerStatus}).

set_peer_sent_seqnos(Peer, HighSeqno, CommittedSeqno, Data) ->
    update_peer_status(
      Peer,
      fun (#peer_status{acked_seqno = AckedSeqno} = PeerStatus) ->
              true = (HighSeqno >= AckedSeqno),
              true = (HighSeqno >= CommittedSeqno),

              %% Note, that we update needs_sync without waiting for the
              %% response. If there's an error, we'll reinitialize peer's
              %% status and decide again if it needs explicit syncing.
              PeerStatus#peer_status{needs_sync = false,
                                     sent_seqno = HighSeqno,
                                     sent_commit_seqno = CommittedSeqno}
      end, Data).

set_peer_acked_seqnos(Peer, HighSeqno, CommittedSeqno, Data) ->
    update_peer_status(
      Peer,
      fun (#peer_status{sent_seqno = SentHighSeqno,
                        sent_commit_seqno = SentCommittedSeqno} = PeerStatus) ->
              true = (SentHighSeqno >= HighSeqno),
              true = (SentCommittedSeqno >= CommittedSeqno),

              PeerStatus#peer_status{acked_seqno = HighSeqno,
                                     acked_commit_seqno = CommittedSeqno}
      end, Data).

set_peer_catchup_in_progress(Peer, Data) ->
    update_peer_status(
      Peer,
      fun (#peer_status{catchup_in_progress = false} = PeerStatus) ->
              PeerStatus#peer_status{catchup_in_progress = true}
      end, Data).

remove_peer_status(Peer, Data) ->
    remove_peer_statuses([Peer], Data).

remove_peer_statuses(Peers, #data{peer_statuses = Tab}) ->
    lists:foreach(
      fun (Peer) ->
              ets:delete(Tab, Peer)
      end, Peers).

maybe_send_requests(Peers, Request, Data, Fun) ->
    NewData = monitor_agents(Peers, Data),
    NotSent = lists:filter(
                fun (Peer) ->
                        {ok, Ref} = get_peer_monitor(Peer, NewData),
                        Opaque = make_agent_opaque(Ref, Peer, Request),
                        not Fun(Peer, Opaque)
                end, Peers),

    {NewData, NotSent}.

make_agent_opaque(Ref, Peer, Request) ->
    {agent_response, Ref, Peer, Request}.

send_requests(Peers, Request, Data, Fun) ->
    {NewData, []} =
        maybe_send_requests(
          Peers, Request, Data,
          fun (Peer, Opaque) ->
                  Fun(Peer, Opaque),
                  true
          end),
    NewData.

send_local_establish_term(Metadata,
                          #data{history_id = HistoryId, term = Term} = Data) ->
    Peers = [?SELF_PEER],
    mark_status_requested(Peers, Data),
    Position = get_position(Metadata),

    send_requests(
      Peers, {establish_term, HistoryId, Term, Position}, Data,
      fun (_Peer, Opaque) ->
              self() ! {Opaque, {ok, Metadata}}
      end).

send_establish_term(Peers, Metadata,
                    #data{history_id = HistoryId, term = Term} = Data) ->
    mark_status_requested(Peers, Data),
    Position = get_position(Metadata),
    Request = {establish_term, HistoryId, Term, Position},
    send_requests(
      Peers, Request, Data,
      fun (Peer, Opaque) ->
              ?DEBUG("Sending establish_term request to peer ~p. "
                     "Term = ~p. History Id: ~p. "
                     "Log position: ~p.",
                     [Peer, Term, HistoryId, Position]),

              chronicle_agent:establish_term(Peer, Opaque,
                                             HistoryId, Term, Position)
      end).

replicate_to_peers(PeerSeqnos0, Data) ->
    PeerSeqnos = maps:from_list(PeerSeqnos0),
    Peers = maps:keys(PeerSeqnos),

    {NewData, CatchupPeers} = send_append(Peers, PeerSeqnos, Data),
    catchup_peers(CatchupPeers, PeerSeqnos, NewData).

send_append(Peers, PeerSeqnos,
            #data{history_id = HistoryId,
                  term = Term,
                  committed_seqno = CommittedSeqno,
                  high_seqno = HighSeqno} = Data) ->
    Request = {append, HistoryId, Term, CommittedSeqno, HighSeqno},

    maybe_send_requests(
      Peers, Request, Data,
      fun (Peer, Opaque) ->
              PeerSeqno = maps:get(Peer, PeerSeqnos),
              case get_entries(PeerSeqno, Data) of
                  {ok, Entries} ->
                      set_peer_sent_seqnos(Peer, HighSeqno,
                                           CommittedSeqno, Data),
                      ?DEBUG("Sending append request to peer ~p.~n"
                             "History Id: ~p~n"
                             "Term: ~p~n"
                             "Committed Seqno: ~p~n"
                             "Peer Seqno: ~p~n"
                             "Entries:~n~p",
                             [Peer, HistoryId, Term,
                              CommittedSeqno, PeerSeqno, Entries]),

                      chronicle_agent:append(Peer, Opaque,
                                             HistoryId, Term, CommittedSeqno,
                                             PeerSeqno, Entries),
                      true;
                  need_catchup ->
                      false
              end
      end).

catchup_peers(Peers, PeerSeqnos, #data{catchup_pid = Pid} = Data) ->
    %% TODO: demonitor_agents() is needed to make sure that if there are any
    %% outstanding requests to the peers, we'll ignore their responses if we
    %% wind up receiving them. Consider doing something cleaner than this.
    NewData = monitor_agents(Peers, demonitor_agents(Peers, Data)),
    lists:foreach(
      fun (Peer) ->
              set_peer_catchup_in_progress(Peer, NewData),

              {ok, Ref} = get_peer_monitor(Peer, NewData),
              PeerSeqno = maps:get(Peer, PeerSeqnos),
              Opaque = make_agent_opaque(Ref, Peer, catchup),
              chronicle_catchup:catchup_peer(Pid, Opaque, Peer, PeerSeqno)
      end, Peers),

    NewData.

maybe_cancel_peer_catchup(Peer, #data{catchup_pid = Pid} = Data) ->
    case get_peer_status(Peer, Data) of
        {ok, #peer_status{catchup_in_progress = true}} ->
            chronicle_catchup:cancel_catchup(Pid, Peer);
        _ ->
            ok
    end.

%% TODO: think about how to backfill peers properly
get_entries(Seqno, #data{pending_entries = PendingEntries} = Data) ->
    LocalCommittedSeqno = get_local_committed_seqno(Data),
    case Seqno < LocalCommittedSeqno of
        true ->
            %% TODO: consider triggerring catchup even if we've got all the
            %% entries to send, but there more than some configured number of
            %% them.
            case get_local_log(Seqno + 1, LocalCommittedSeqno) of
                {ok, BackfillEntries} ->
                    {ok, BackfillEntries ++ queue:to_list(PendingEntries)};
                {error, compacted} ->
                    need_catchup
            end;
        false ->
            Entries = chronicle_utils:queue_dropwhile(
                        fun (Entry) ->
                                Entry#log_entry.seqno =< Seqno
                        end, PendingEntries),
            {ok, queue:to_list(Entries)}
    end.

get_local_committed_seqno(Data) ->
    {ok, PeerStatus} = get_peer_status(?SELF_PEER, Data),
    PeerStatus#peer_status.acked_commit_seqno.

get_local_log(StartSeqno, EndSeqno) ->
    chronicle_agent:get_log_committed(StartSeqno, EndSeqno).

send_ensure_term(Peers, Request,
                 #data{history_id = HistoryId, term = Term} = Data) ->
    send_requests(
      Peers, Request, Data,
      fun (Peer, Opaque) ->
              chronicle_agent:ensure_term(Peer, Opaque, HistoryId, Term)
      end).

send_request_peer_position(Peer, Data) ->
    send_request_position([Peer], Data).

send_request_position(Peers, Data) ->
    mark_status_requested(Peers, Data),
    send_ensure_term(Peers, peer_position, Data).

reply_request(ReplyTo, Reply) ->
    chronicle_server:reply_request(ReplyTo, Reply).

monitor_agents(Peers,
               #data{monitors_peers = MPeers, monitors_refs = MRefs} = Data) ->
    {NewMPeers, NewMRefs} =
        lists:foldl(
          fun (Peer, {AccMPeers, AccMRefs} = Acc) ->
                  case maps:is_key(Peer, AccMPeers) of
                      true ->
                          %% already monitoring
                          Acc;
                      false ->
                          MRef = chronicle_agent:monitor(Peer),
                          {AccMPeers#{Peer => MRef}, AccMRefs#{MRef => Peer}}
                  end
          end, {MPeers, MRefs}, Peers),

    Data#data{monitors_peers = NewMPeers, monitors_refs = NewMRefs}.

demonitor_agents(Peers,
                 #data{monitors_peers = MPeers, monitors_refs = MRefs} =
                     Data) ->
    {NewMPeers, NewMRefs} =
        lists:foldl(
          fun (Peer, {AccMPeers, AccMRefs} = Acc) ->
                  case maps:take(Peer, AccMPeers) of
                      {MRef, NewAccMPeers} ->
                          erlang:demonitor(MRef, [flush]),
                          {NewAccMPeers, maps:remove(MRef, AccMRefs)};
                      error ->
                          Acc
                  end
          end, {MPeers, MRefs}, Peers),

    Data#data{monitors_peers = NewMPeers, monitors_refs = NewMRefs}.

take_monitor(MRef,
             #data{monitors_peers = MPeers, monitors_refs = MRefs} = Data) ->
    case maps:take(MRef, MRefs) of
        {Peer, NewMRefs} ->
            NewMPeers = maps:remove(Peer, MPeers),
            {ok, Peer, Data#data{monitors_peers = NewMPeers,
                                 monitors_refs = NewMRefs}};
        error ->
            not_found
    end.

get_peer_monitor(Peer, #data{monitors_peers = MPeers}) ->
    case maps:find(Peer, MPeers) of
        {ok, _} = Ok ->
            Ok;
        error ->
            not_found
    end.

deduce_committed_seqno(#data{quorum_peers = Peers,
                             quorum = Quorum} = Data) ->
    PeerSeqnos =
        lists:filtermap(
          fun (Peer) ->
                  case get_peer_status(Peer, Data) of
                      {ok, #peer_status{acked_seqno = AckedSeqno}}
                        when AckedSeqno =/= ?NO_SEQNO ->
                          {true, {Peer, AckedSeqno}};
                      _ ->
                          false
                  end
          end, Peers),

    deduce_committed_seqno(PeerSeqnos, Quorum).

deduce_committed_seqno(PeerSeqnos0, Quorum) ->
    PeerSeqnos =
        %% Order peers in the decreasing order of their seqnos.
        lists:sort(fun ({_PeerA, SeqnoA}, {_PeerB, SeqnoB}) ->
                           SeqnoA >= SeqnoB
                   end, PeerSeqnos0),

    deduce_committed_seqno_loop(PeerSeqnos, Quorum, sets:new()).

deduce_committed_seqno_loop([], _Quroum, _Votes) ->
    no_quorum;
deduce_committed_seqno_loop([{Peer, Seqno} | Rest], Quorum, Votes) ->
    NewVotes = sets:add_element(Peer, Votes),
    case have_quorum(NewVotes, Quorum) of
        true ->
            {ok, Seqno};
        false ->
            deduce_committed_seqno_loop(Rest, Quorum, NewVotes)
    end.

-ifdef(TEST).
deduce_committed_seqno_test() ->
    Peers = [a, b, c, d, e],
    Quorum = {joint,
              {all, sets:from_list([a])},
              {majority, sets:from_list(Peers)}},

    ?assertEqual(no_quorum, deduce_committed_seqno([], Quorum)),
    ?assertEqual(no_quorum, deduce_committed_seqno([{a, 1}, {b, 3}], Quorum)),
    ?assertEqual({ok, 1},
                 deduce_committed_seqno([{a, 1}, {b, 1},
                                         {c, 3}, {d, 1}, {e, 2}], Quorum)),
    ?assertEqual({ok, 1},
                 deduce_committed_seqno([{a, 1}, {b, 1},
                                         {c, 3}, {d, 3}, {e, 2}], Quorum)),
    ?assertEqual({ok, 2},
                 deduce_committed_seqno([{a, 2}, {b, 1},
                                         {c, 3}, {d, 3}, {e, 2}], Quorum)),
    ?assertEqual({ok, 1},
                 deduce_committed_seqno([{a, 1}, {b, 3},
                                         {c, 3}, {d, 3}, {e, 2}], Quorum)),
    ?assertEqual({ok, 3},
                 deduce_committed_seqno([{a, 3}, {b, 3},
                                         {c, 3}, {d, 3}, {e, 2}], Quorum)),

    NewPeers = [a, b, c],
    JointQuorum = {joint,
                   {all, sets:from_list([a])},
                   {joint,
                    {majority, sets:from_list(Peers)},
                    {majority, sets:from_list(NewPeers)}}},

    ?assertEqual(no_quorum,
                 deduce_committed_seqno([{c, 1}, {d, 1}, {e, 1}], JointQuorum)),
    ?assertEqual({ok, 1},
                 deduce_committed_seqno([{a, 1}, {b, 1},
                                         {c, 2}, {d, 2}, {e, 2}], JointQuorum)),
    ?assertEqual({ok, 1},
                 deduce_committed_seqno([{a, 2}, {b, 2},
                                         {c, 1}, {d, 1}, {e, 1}], JointQuorum)),
    ?assertEqual({ok, 1},
                 deduce_committed_seqno([{a, 1}, {b, 2}, {c, 2},
                                         {d, 3}, {e, 1}], JointQuorum)),
    ?assertEqual({ok, 2},
                 deduce_committed_seqno([{a, 2}, {b, 2}, {c, 1},
                                         {d, 3}, {e, 1}], JointQuorum)).
-endif.

stop(Reason, State, Data) ->
    stop(Reason, [], State, Data).

stop(Reason, ExtraEffects, State,
     #data{parent = Pid,
           peers = Peers,
           config_change_reply_to = ConfigReplyTo} = Data)
  when State =:= establish_term;
       State =:= proposing ->
    chronicle_server:proposer_stopping(Pid, Reason),
    {NewData0, Effects} = unpostpone_config_requests(Data),

    %% Demonitor all agents so we don't process any more requests from them.
    NewData1 = demonitor_agents(Peers, NewData0),

    %% Reply to all in-flight sync_quorum requests
    sync_quorum_reply_not_leader(Data),

    case ConfigReplyTo of
        undefined ->
            ok;
        _ ->
            reply_request(ConfigReplyTo, {error, {leader_error, leader_lost}})
    end,

    NewData2 =
        case State =:= proposing of
            true ->
                %% Make an attempt to notify local agent about the latest
                %% committed seqno, so chronicle_rsm-s can reply to clients
                %% whose commands got committed.
                %%
                %% But this can be and needs to be done only if we've
                %% established the term on a quorum of nodes (that is, our
                %% state is 'proposing').
                sync_local_agent(NewData1),
                stop_catchup_process(NewData1);
            false ->
                NewData1
        end,

    {next_state, {stopped, Reason}, NewData2, Effects ++ ExtraEffects};
stop(_Reason, ExtraEffects, {stopped, _}, Data) ->
    {keep_state, Data, ExtraEffects}.

sync_local_agent(#data{history_id = HistoryId,
                       term = Term,
                       committed_seqno = CommittedSeqno}) ->
    Result =
        (catch chronicle_agent:local_mark_committed(HistoryId,
                                                    Term, CommittedSeqno)),
    case Result of
        ok ->
            ok;
        Other ->
            ?DEBUG("Failed to synchronize with local agent.~n"
                   "History id: ~p~n"
                   "Term: ~p~n"
                   "Committed seqno: ~p~n"
                   "Error:~n~p",
                   [HistoryId, Term, CommittedSeqno, Other])
    end.

reply_not_leader(ReplyTo) ->
    reply_request(ReplyTo, {error, {leader_error, not_leader}}).

require_self_quorum(Quorum) ->
    {joint, {all, sets:from_list([?SELF_PEER])}, Quorum}.

get_establish_quorum(#metadata{peer = Self} = Metadata) ->
    translate_quorum(chronicle_utils:get_establish_quorum(Metadata), Self).

get_append_quorum(Config, #data{peer = Self}) ->
    translate_quorum(chronicle_utils:get_append_quorum(Config), Self).

translate_peers(Peers, Self) ->
    case sets:is_element(Self, Peers) of
        true ->
            sets:add_element(?SELF_PEER, sets:del_element(Self, Peers));
        false ->
            Peers
    end.

translate_quorum({all, Peers}, Self) ->
    {all, translate_peers(Peers, Self)};
translate_quorum({majority, Peers}, Self) ->
    {majority, translate_peers(Peers, Self)};
translate_quorum({joint, Quorum1, Quorum2}, Self) ->
    {joint,
     translate_quorum(Quorum1, Self),
     translate_quorum(Quorum2, Self)}.

get_live_peers(Peers) ->
    LivePeers = sets:from_list(chronicle_peers:get_live_peers()),
    lists:filter(
      fun (Peer) ->
              case Peer of
                  ?SELF_PEER ->
                      true;
                  _ ->
                      sets:is_element(Peer, LivePeers)
              end
      end, Peers).
