-module(msghub).
-author('manuel@altenwald.com').

-behaviour(gen_server).

% API
-export([
    start_link/1,
    stop/1,
    publish/2,
    subscribe/2,
    unsubscribe/2,
    unsubscribe_all/1
]).

% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    code_change/3,
    terminate/2
]).

-define(TIMEOUT,       20). % sec

% from seconds to ...
-define(MICROSEC, 1000000).
-define(MSEC,        1000).

-type sub() :: {port(), inet:ip(), inet:port()} | port().
-type subs() :: [sub()].

-record(state, {
    name :: binary(),
    subs = [] :: subs(),
    timeout :: pos_integer()
}).

%%====================================================================
%% API
%%====================================================================

start_link(Chan) ->
    {ok, PID} = gen_server:start_link({global, Chan}, ?MODULE, [Chan], []),
    pg2:join(channels, PID),
    {ok, PID}.

publish(Chan, Msg) ->
    start_if_not_exist(Chan),
    gen_server:cast({global, Chan}, {pub, Msg}).

subscribe(Chan, Info) ->
    start_if_not_exist(Chan),
    gen_server:cast({global, Chan}, {sub, Info}).

unsubscribe(Chan, Info) ->
    gen_server:cast({global, Chan}, {unsub, Info}).

unsubscribe_all(Info) ->
    lists:foreach(fun(PID) ->
        gen_server:cast(PID, {unsub, Info})
    end, pg2:get_members(channels)).

stop(Chan) ->
    pg2:leave(channels, global:whereis_name(Chan)),
    gen_server:call({global, Chan}, stop).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Chan]) ->
    Timeout = case application:get_env(msghub, udp, #{}) of
        #{timeout := T} -> T;
        _ -> ?TIMEOUT
    end,
    erlang:send_after(Timeout * ?MSEC, self(), timeout),
    {ok, #state{name = Chan, timeout = Timeout}}.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

handle_cast({pub, Msg}, #state{subs=Subs}=State) ->
    broadcast(Subs, Msg),
    {noreply, State};

handle_cast({sub, Info}, #state{subs=Subs}=State) when is_port(Info) ->
    lager:debug("subscribed ~p", [Info]),
    {noreply, State#state{subs=[Info|Subs]}};

handle_cast({sub, {_,_,_}=Info}, #state{subs=Subs}=State) ->
    lager:debug("subscribed (udp) ~p with timeout!", [Info]),
    {noreply, State#state{subs=[{os:timestamp(),Info}|Subs]}};

handle_cast({unsub, Info}, #state{name=Name, subs=Subs}=State) ->
    NewSubs = lists:filter(fun
        (Sub) when is_port(Sub) andalso Sub =:= Info ->
            lager:debug("unsubscribed (udp) ~p", [Sub]),
            gen_tcp:send(Sub, <<"UNSUBSCRIBED ", Name/binary, "\n">>),
            false;
        ({_,{Socket,IP,Port}=Sub}) when Sub =:= Info ->
            lager:debug("unsubscribed (tcp) ~p", [Sub]),
            gen_udp:send(Socket, IP, Port, <<"UNSUBSCRIBED ", Name/binary, "\n">>),
            false;
        (_) ->
            true
    end, Subs),
    {noreply, State#state{subs=NewSubs}}.

handle_info(timeout, #state{subs=Subs, timeout=Timeout}=State) ->
    Now = os:timestamp(),
    NewSubs = lists:filter(fun
        ({T,_Sub}) ->
            case timer:now_diff(Now, T) < (Timeout * ?MICROSEC) of
                true ->
                    true;
                false ->
                    lager:debug("unsubscribed (udp) ~p; timeout!", [_Sub]),
                    false
            end;
        (_) -> true
    end, Subs),
    erlang:send_after(Timeout * ?MSEC, self(), timeout),
    {noreply, State#state{subs=NewSubs}}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{name=Name, subs=Subs}) ->
    broadcast(Subs, <<"DESTROYED ", Name/binary>>).

%%====================================================================
%% Test functions
%%====================================================================

start_if_not_exist(Chan) ->
    case global:whereis_name(Chan) of
        PID when is_pid(PID) -> {ok, PID};
        undefined -> start_link(Chan)
    end.

broadcast(Subs, Msg) ->
    lists:foreach(fun
        (Sub) when is_port(Sub) ->
            lager:debug("message for ~p: ~p", [Sub, Msg]),
            gen_tcp:send(Sub, <<Msg/binary, "\n">>);
        ({_,{Socket, IP, Port}=Sub}) ->
            lager:debug("message for ~p: ~p", [Sub, Msg]),
            gen_udp:send(Socket, IP, Port, <<Msg/binary, "\n">>)
    end, Subs).

%%====================================================================
%% Test functions
%%====================================================================

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

init_test() ->
    catch msghub:stop(<<"chan1">>), % ensure always is stopped at begining
    ?assertEqual(undefined, whereis(?MODULE)),
    msghub:start_link(<<"chan1">>),
    ?assertNotEqual(undefined, global:whereis_name(<<"chan1">>)),
    msghub:stop(<<"chan1">>),
    ?assertEqual(undefined, global:whereis_name(<<"chan1">>)),
    ok.

init_timeout_test() ->
    application:set_env(msghub, udp, #{timeout => ?TIMEOUT}),
    catch msghub:stop(<<"chan1">>), % ensure always is stopped at begining
    ?assertEqual(undefined, whereis(?MODULE)),
    msghub:start_link(<<"chan1">>),
    ?assertNotEqual(undefined, global:whereis_name(<<"chan1">>)),
    msghub:stop(<<"chan1">>),
    ?assertEqual(undefined, global:whereis_name(<<"chan1">>)),
    ok.

timeout_test() ->
    application:set_env(msghub, udp, #{timeout => 1}),
    catch msghub:stop(<<"chan1">>), % ensure always is stopped at begining
    {ok,PID} = msghub:start_link(<<"chan1">>),
    msghub:subscribe(<<"chan1">>, {1,2,3}),
    ?assertMatch(#state{subs=[_]}, sys:get_state(PID)),
    timer:sleep(2000),
    ?assertMatch(#state{subs=[]}, sys:get_state(PID)),
    msghub:stop(<<"chan1">>),
    ok.

multi_timeout_test() ->
    State1 = #state{subs=[socket, {{0,0,0},{2,3,4}}, {os:timestamp(),{1,2,3}}],
                    timeout=100},
    ?assertMatch({noreply, #state{subs=[socket,_]}}, handle_info(timeout, State1)),
    ok.

code_change_test() ->
    catch msghub:stop(<<"chan1">>), % ensure always is stopped at begining
    {ok,PID} = msghub:start_link(<<"chan1">>),
    ok = sys:suspend(PID),
    ok = sys:change_code(PID, ?MODULE, "0", []),
    ok = sys:resume(PID),
    msghub:stop(<<"chan1">>),
    ok.

-endif.
