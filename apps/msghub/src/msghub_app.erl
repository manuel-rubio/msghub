-module(msghub_app).
-author('manuel@altenwald.com').

-behaviour(application).
-behaviour(supervisor).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%% Application callbacks
-export([start/2, stop/1]).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

init(Children) ->
    {ok, {{one_for_one, 100, 1}, Children}}.

%%====================================================================
%% API
%%====================================================================

start(_StartType, _StartArgs) ->
    pg2:create(channels),
    supervisor:start_link({local, ?SERVER}, ?MODULE,
        msghub_tcp:start() ++
        msghub_udp:start()
    ).

%%--------------------------------------------------------------------
stop(_State) ->
    ok.

%%====================================================================
%% Test functions
%%====================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

init_test() ->
    ?assertEqual({ok, {{one_for_one, 100, 1}, []}}, init([])).

start_test() ->
    application:set_env(msghub, udp, []),
    application:set_env(msghub, tcp, []),
    msghub_app:start(normal, []),
    ?assertEqual([], supervisor:which_children(msghub_app)),
    msghub_app:stop([]).

-endif.
