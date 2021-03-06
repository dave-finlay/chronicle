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
%% A supervisor for processes that require the system to be provisioned to
%% run.
-module(chronicle_rsm_sup).

-behavior(dynamic_supervisor).

-include("chronicle.hrl").

-define(SERVER, ?SERVER_NAME(?MODULE)).

-export([start_link/0]).
-export([init/1, handle_event/2, child_specs/1]).

start_link() ->
    dynamic_supervisor:start_link(?START_NAME(?MODULE), ?MODULE, []).

%% callbacks
init([]) ->
    Self = self(),
    chronicle_events:subscribe(
      fun (Event) ->
              case Event of
                  {new_config, Config, _} ->
                      %% TODO: this is going to wake up the process needlessly
                      %% all the time; having more granular events
                      dynamic_supervisor:send_event(Self, {new_config, Config});
                  _ ->
                      ok
              end
      end),

    {ok, Metadata} = chronicle_agent:get_metadata(),

    %% TODO: reconsider the strategy
    Flags = #{strategy => one_for_one,
              intensity => 3,
              period => 10},

    {ok, Flags, chronicle_utils:config_rsms(Metadata#metadata.config)}.

handle_event({new_config, Config}, _) ->
    {noreply, chronicle_utils:config_rsms(Config)}.

child_specs(RSMs) ->
    lists:map(
      fun ({Name, #rsm_config{module = Module, args = Args}}) ->
              #{id => Name,
                start => {chronicle_single_rsm_sup,
                          start_link,
                          [Name, Module, Args]},
                restart => permanent,
                type => supervisor}
      end, maps:to_list(RSMs)).
