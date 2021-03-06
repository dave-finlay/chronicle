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

-ifdef(TEST).
-define(PEER(), vnet:vnode()).
-define(START_NAME(Name), {via, vnet, Name}).
-define(SERVER_NAME(Name), {via, vnet, Name}).
-define(SERVER_NAME(Peer, Name), {via, vnet, {Peer, Name}}).
-define(SEND(Name, Msg, _Options),
        begin
            {via, vnet, _} = Name,
            try
                vnet:send(element(3, Name), Msg)
            catch
                exit:{badarg, {_, _}} ->
                    %% vnet:send() may fail with this error when Name can't be
                    %% resolved. This is different from how erlang:send/3
                    %% behaves, so we are just catching the error.
                    ok
            end
        end).
-define(ETS_TABLE(Name), list_to_atom("ets-"
                                      ++ atom_to_list(vnet:vnode())
                                      ++ "-"
                                      ++ atom_to_list(Name))).
-else.
-define(PEER(), node()).
-define(START_NAME(Name), {local, Name}).
-define(SERVER_NAME(Name), Name).
-define(SERVER_NAME(Peer, Name), {Name, Peer}).
-define(SEND(Name, Msg, Options), erlang:send(Name, Msg, Options)).
-define(ETS_TABLE(Name), Name).
-endif.

-define(SEND(Name, Msg), ?SEND(Name, Msg, [])).

-define(SELF_PEER, 'self@nohost').
-define(NO_PEER, 'nonode@nohost').
-define(NO_HISTORY, <<"no-history">>).
-define(NO_TERM, {0, <<"no-term">>}).
-define(NO_SEQNO, 0).

-record(rsm_config, { module :: module(),
                      args = [] :: list() }).
-record(config, { voters :: [chronicle:peer()],
                  state_machines :: #{atom() => #rsm_config{} }}).
-record(transition,
        { current_config :: #config{},
          future_config :: #config{} }).
-record(rsm_command,
        { rsm_name :: atom(),
          command :: term() }).

-record(log_entry,
        { history_id :: chronicle:history_id(),
          term :: chronicle:leader_term(),
          seqno :: chronicle:seqno(),
          value :: #config{} | #transition{} | #rsm_command{}}).

-record(metadata, { peer,
                    history_id,
                    term,
                    term_voted,
                    high_seqno,
                    committed_seqno,
                    config,
                    config_revision,
                    pending_branch }).

-record(branch, {history_id,
                 coordinator,
                 peers,

                 %% The following fields are only set on the branch
                 %% coordinator node.
                 status :: ok
                         | unknown
                         | {concurrent_branch, #branch{}}
                         | {incompatible_histories,
                            [{chronicle:history_id(), [chronicle:peer()]}]},
                 opaque}).

-define(DEBUG(Fmt, Args), ?LOG(debug, Fmt, Args)).
-define(INFO(Fmt, Args), ?LOG(info, Fmt, Args)).
-define(WARNING(Fmt, Args), ?LOG(warning, Fmt, Args)).
-define(ERROR(Fmt, Args), ?LOG(error, Fmt, Args)).

-define(DEBUG(Msg), ?DEBUG(Msg, [])).
-define(INFO(Msg), ?INFO(Msg, [])).
-define(WARNING(Msg), ?WARNING(Msg, [])).
-define(ERROR(Msg), ?ERROR(Msg, [])).

-define(CHRONICLE_LOGGER, '$chronicle_logger').
-define(LOG(Level, Fmt, Args),
        (persistent_term:get(?CHRONICLE_LOGGER))(
          Level, Fmt, Args,
          #{file => ?FILE,
            line => ?LINE,
            module => ?MODULE,
            function => ?FUNCTION_NAME,
            arity => ?FUNCTION_ARITY})).

-define(CHECK(Cond1, Cond2),
        case Cond1 of
            ok ->
                Cond2;
            __Error ->
                __Error
        end).
-define(CHECK(Cond1, Cond2, Cond3),
        ?CHECK(Cond1, ?CHECK(Cond2, Cond3))).
-define(CHECK(Cond1, Cond2, Cond3, Cond4),
        ?CHECK(Cond1, ?CHECK(Cond2, Cond3, Cond4))).

-define(FLUSH(Pattern),
        (fun __Loop(__N) ->
                 receive
                     Pattern ->
                         __Loop(__N + 1)
                 after
                     0 ->
                         __N
                 end
         end)(0)).

-define(CRC_BITS, 32).
-define(CRC_BYTES, (?CRC_BITS bsr 3)).
