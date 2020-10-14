-module(router_metrics).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([start_link/1,
         routing_offer_observe/4, routing_packet_observe/3,
         packet_observe_start/3, packet_observe_end/3,
         downlink_inc/2,
         decoder_observe/3,
         console_api_observe/3,
         ws_state/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).

-define(METRICS_TICK_INTERVAL, timer:seconds(10)).
-define(METRICS_TICK, '__router_metrics_tick').

-define(BASE, "router_").
-define(ROUTING_OFFER, ?BASE ++ "device_routing_offer_duration").
-define(ROUTING_PACKET, ?BASE ++ "device_routing_packet_duration").
-define(PACKET, ?BASE ++ "device_packet_duration").
-define(DOWNLINK, ?BASE ++ "device_downlink_packet").
-define(DC, ?BASE ++ "dc_balance").
-define(SC_ACTIVE_COUNT, ?BASE ++ "state_channel_active_count").
-define(SC_ACTIVE, ?BASE ++ "state_channel_active").
-define(DECODED_TIME, ?BASE ++ "decoder_decoded_duration").
-define(CONSOLE_API_TIME, ?BASE ++ "console_api_duration").
-define(WS, ?BASE ++ "ws_state").

-define(METRICS, [{histogram, ?ROUTING_OFFER, [type, status, reason], "Routing Offer duration", [50, 100, 250, 500, 1000]},
                  {histogram, ?ROUTING_PACKET, [type, status], "Routing Packet duration", [50, 100, 250, 500, 1000]},
                  {histogram, ?PACKET, [], "Packet duration", [50, 100, 250, 500, 1000, 2000]},
                  {counter, ?DOWNLINK, [type, status], "Downlink count"},
                  {gauge, ?DC, [], "DC balance"},
                  {gauge, ?SC_ACTIVE_COUNT, [], "Active State Channel count"},
                  {gauge, ?SC_ACTIVE, [], "Active State Channel balance"},
                  {histogram, ?DECODED_TIME, [type, status], "Decoder decoded duration", [50, 100, 250, 500, 1000]},
                  {histogram, ?CONSOLE_API_TIME, [type, status], "Console API duration", [100, 250, 500, 1000]},
                  {boolean, ?WS, [], "Websocket State"}]).

-record(state, {end_to_end :: map()}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?SERVER, Args, []).

-spec routing_offer_observe(join | packet, accepted | rejected, any(), non_neg_integer()) -> ok.
routing_offer_observe(Type, Status, Reason, Time) when (Type == join orelse Type == packet)
                                                       andalso (Status == accepted orelse Status == rejected) ->
    ok = prometheus_histogram:observe(?ROUTING_OFFER, [Type, Status, Reason], Time).

-spec routing_packet_observe(join | packet, accepted | rejected, non_neg_integer()) -> ok.
routing_packet_observe(Type, Status, Time) when (Type == join orelse Type == packet)
                                                andalso (Status == accepted orelse Status == rejected) ->
    ok = prometheus_histogram:observe(?ROUTING_PACKET, [Type, Status], Time).

-spec packet_observe_start(binary(), binary(), non_neg_integer()) -> ok.
packet_observe_start(PacketHash, PubKeyBin, Time) ->
    gen_server:cast(?MODULE, {packet_observe_start, PacketHash, PubKeyBin, Time}).

-spec packet_observe_end(binary(), binary(), non_neg_integer()) -> ok.
packet_observe_end(PacketHash, PubKeyBin, Time) ->
    gen_server:cast(?MODULE, {packet_observe_end, PacketHash, PubKeyBin, Time}).

-spec downlink_inc(atom(), ok | error) -> ok.
downlink_inc(Type, Status) ->
    ok = prometheus_counter:inc(?DOWNLINK, [Type, Status]).

-spec decoder_observe(atom(), ok | error, non_neg_integer()) -> ok.
decoder_observe(Type, Status, Time) when Status == ok orelse Status == error ->
    ok = prometheus_histogram:observe(?DECODED_TIME, [Type, Status], Time).

-spec console_api_observe(atom(), atom(), non_neg_integer()) -> ok.
console_api_observe(Type, Status, Time) ->
    ok = prometheus_histogram:observe(?CONSOLE_API_TIME, [Type, Status], Time).

-spec ws_state(boolean()) -> ok.
ws_state(State) ->
    ok = prometheus_boolean:set(?WS, [], State).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    Port = maps:get(port, Args, 3000),
    ElliOpts = [{callback, router_metrics_handler},
                {callback_args, #{}},
                {port, Port}],
    {ok, _Pid} = elli:start_link(ElliOpts),
    lists:foreach(
      fun({counter, Name, Labels, Help}) ->
              _ = prometheus_counter:declare([{name, Name},
                                              {help, Help},
                                              {labels, Labels}]);
         ({gauge, Name, Labels, Help}) ->
              _ = prometheus_gauge:declare([{name, Name},
                                            {help, Help},
                                            {labels, Labels}]);
         ({histogram, Name, Labels, Help, Buckets}) ->
              _ = prometheus_histogram:declare([{name, Name},
                                                {help, Help},
                                                {labels, Labels},
                                                {buckets, Buckets}]);
         ({boolean, Name, Labels, Help}) ->
              _ = prometheus_boolean:declare([{name, Name},
                                              {help, Help},
                                              {labels, Labels}])
      end,
      ?METRICS),
    _ = schedule_next_tick(),
    {ok, #state{end_to_end = #{}}}.

handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.


handle_cast({packet_observe_start, PacketHash, PubKeyBin, Start}, #state{end_to_end=EToE}=State) ->
    {noreply, State#state{end_to_end=maps:put({PacketHash, PubKeyBin}, Start, EToE)}};
handle_cast({packet_observe_end, PacketHash, PubKeyBin, End}, #state{end_to_end=EToE}=State) ->
    case maps:get({PacketHash, PubKeyBin}, EToE, undefined) of
        undefined ->
            {noreply, State};
        Start ->
            ok = prometheus_histogram:observe(?PACKET, [], End-Start),
            {noreply, State#state{end_to_end=maps:remove({PacketHash, PubKeyBin}, EToE)}}
    end;
handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info(?METRICS_TICK, State) ->
    erlang:spawn(
      fun() ->
              ok = record_dc_balance(),
              ok = record_state_channels()
      end),
    _ = schedule_next_tick(),
    {noreply, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p, ~p", [_Msg, State]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec record_dc_balance() -> ok.
record_dc_balance() ->
    Ledger = blockchain:ledger(blockchain_worker:blockchain()),
    Owner = blockchain_swarm:pubkey_bin(),
    case blockchain_ledger_v1:find_dc_entry(Owner, Ledger) of
        {error, _} ->
            ok;
        {ok, Entry} ->
            Balance = blockchain_ledger_data_credits_entry_v1:balance(Entry),
            _ = prometheus_gauge:set(?DC, Balance),
            ok
    end.

-spec record_state_channels() -> ok.
record_state_channels() ->
    ActiveSCCount = blockchain_state_channels_server:get_active_sc_count(),
    _ = prometheus_gauge:set(?SC_ACTIVE_COUNT, ActiveSCCount),
    case blockchain_state_channels_server:active_sc() of
        undefined ->
            _ = prometheus_gauge:set(?SC_ACTIVE, [], 0);
        ActiveSC ->
            TotalDC = blockchain_state_channel_v1:total_dcs(ActiveSC),
            DCLeft = blockchain_state_channel_v1:amount(ActiveSC)-TotalDC,
            _ = prometheus_gauge:set(?SC_ACTIVE, [], DCLeft)
    end,
    ok.

-spec schedule_next_tick() -> reference().
schedule_next_tick() ->
    erlang:send_after(?METRICS_TICK_INTERVAL, self(), ?METRICS_TICK).
