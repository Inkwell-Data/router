%%%-------------------------------------------------------------------
%% @doc
%% == Router MQTT Channel ==
%% @end
%%%-------------------------------------------------------------------
-module(router_mqtt_channel).

-behaviour(gen_event).

%% ------------------------------------------------------------------
%% gen_event Function Exports
%% ------------------------------------------------------------------
-export([init/1,
         handle_event/2,
         handle_call/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(PING_TIMEOUT, 25000).

-record(state, {channel :: router_channel:channel(),
                connection :: pid(),
                pubtopic :: binary()}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(Channel) ->
    lager:info("~p init with ~p", [?MODULE, Channel]),
    DeviceID = router_channel:device_id(Channel),
    ChannelName = router_channel:name(Channel),
    #{endpoint := Endpoint, topic := Topic} = router_channel:args(Channel),
    FixedTopic = topic(Topic),
    case connect(Endpoint, DeviceID, ChannelName) of
        {ok, Conn} ->
            erlang:send_after(?PING_TIMEOUT, self(), ping),
            PubTopic = erlang:list_to_binary(io_lib:format("~shelium/~s/rx", [FixedTopic, DeviceID])),
            SubTopic = erlang:list_to_binary(io_lib:format("~shelium/~s/tx/#", [FixedTopic, DeviceID])),
            %% TODO use a better QoS to add some back pressure
            emqtt:subscribe(Conn, {SubTopic, 0}),
            {ok, #state{channel=Channel,
                        connection=Conn,
                        pubtopic=PubTopic}};
        {error, Reason} ->
            {error, Reason}
    end.

handle_event({data, Data}, #state{channel=Channel, connection=Conn, pubtopic=Topic}=State) ->
    DeviceID = router_channel:device_id(Channel),
    ID = router_channel:id(Channel),
    Fcnt = maps:get(sequence, Data),
    case router_channel:dupes(Channel) of
        true ->
            Res = emqtt:publish(Conn, Topic, encode_data(Data), 0),
            ok = handle_publish_res(Res, Channel, Data),
            lager:info("published: ~p result: ~p", [Data, Res]);
        false ->
            case throttle:check(packet_dedup, {DeviceID, ID, Fcnt}) of
                {ok, _, _} ->
                    Res = emqtt:publish(Conn, Topic, encode_data(Data), 0),
                    ok = handle_publish_res(Res, Channel, Data),
                    lager:info("published: ~p result: ~p", [Data, Res]);
                _ ->
                    lager:debug("ignoring duplicate ~p", [Data])
            end
    end,
    {ok, State};
handle_event(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {ok, State}.

handle_call(_Msg, State) ->
    lager:warning("rcvd unknown call msg: ~p", [_Msg]),
    {ok, ok, State}.

handle_info({publish, #{payload := Payload0}}, #state{channel=Channel}=State) ->
    router_device_worker:handle_downlink(Payload0, Channel),
    {ok, State};
handle_info(ping, #state{connection=Connection}=State) ->
    (catch emqtt:ping(Connection)),
    erlang:send_after(25000, self(), ping),
    {ok, State};
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {ok, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, #state{connection=Conn}) ->
    (catch emqtt:disconnect(Conn)).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec encode_data(map()) -> binary().
encode_data(#{payload := Payload}=Map) ->
    jsx:encode(maps:put(payload, base64:encode(Payload), Map)).

-spec handle_publish_res(any(), router_channel:channel(), map()) -> ok.
handle_publish_res(Res, Channel, Data) ->
    DeviceWorkerPid = router_channel:device_worker(Channel),
    Payload = maps:get(payload, Data),
    Result0 = #{channel_id => router_channel:id(Channel),
                channel_name => router_channel:name(Channel),
                port => maps:get(port, Data),
                payload => base64:encode(Payload),
                payload_size => erlang:byte_size(Payload), 
                reported_at => erlang:system_time(seconds),
                rssi => maps:get(rssi, Data),
                snr => maps:get(snr, Data),
                hotspot_name => maps:get(hotspot_name, Data),
                category => <<"up">>,
                frame_up => maps:get(sequence, Data)},
    Result1 = case Res of
                  {ok, PacketID} ->
                      maps:merge(Result0, #{status => success, description => list_to_binary(io_lib:format("Packet ID: ~b", [PacketID]))});
                  ok ->
                      maps:merge(Result0, #{status => success, description => <<"ok">>});
                  {error, Reason} ->
                      maps:merge(Result0, #{status => failure, description => list_to_binary(io_lib:format("~p", [Reason]))})
              end,
    router_device_worker:report_channel_status(DeviceWorkerPid, Result1).

-spec topic(binary() | list()) -> binary().
topic(<<>>) ->
    <<>>;
topic("") ->
    <<>>;
topic(Topic) when is_list(Topic) ->
    topic(erlang:list_to_binary(Topic));
topic(<<"/", Topic/binary>>) ->
    topic(Topic);
topic(Topic) ->
    case binary:last(Topic) == $/ of
        false -> <<Topic/binary, "/">>;
        true -> Topic
    end.

-spec connect(binary(), binary(), any()) -> {ok, pid()} | {error, term()}.
connect(URI, DeviceID, Name) ->
    Opts = [{scheme_defaults, [{mqtt, 1883}, {mqtts, 8883} | http_uri:scheme_defaults()]}, {fragment, false}],
    case http_uri:parse(URI, Opts) of
        {ok, {Scheme, UserInfo, Host, Port, _Path, _Query}} when Scheme == mqtt orelse
                                                                 Scheme == mqtts ->
            %% An optional userinfo subcomponent that may consist of a user name
            %% and an optional password preceded by a colon (:), followed by an
            %% at symbol (@). Use of the format username:password in the userinfo
            %% subcomponent is deprecated for security reasons. Applications
            %% should not render as clear text any data after the first colon
            %% (:) found within a userinfo subcomponent unless the data after
            %% the colon is the empty string (indicating no password).
            {Username, Password} = case binary:split(UserInfo, <<":">>) of
                                       [Un, <<>>] -> {Un, undefined};
                                       [Un, Pw] -> {Un, Pw};
                                       [<<>>] -> {undefined, undefined};
                                       [Un] -> {Un, undefined}
                                   end,
            EmqttOpts = [{host, erlang:binary_to_list(Host)},
                         {port, Port},
                         {clientid, DeviceID}] ++
                [{username, Username} || Username /= undefined] ++
                [{password, Password} || Password /= undefined] ++
                [{clean_start, false},
                 {keepalive, 30},
                 {ssl, Scheme == mqtts}],
            {ok, C} = emqtt:start_link(EmqttOpts),
            case emqtt:connect(C) of
                {ok, _Props} ->
                    lager:info("connect returned ~p", [_Props]),
                    {ok, C};
                {error, Reason} ->
                    lager:info("Failed to connect to ~p ~p : ~p", [Host, Port,
                                                                   Reason]),
                    {error, Reason}
            end;
        _ ->
            lager:info("BAD MQTT URI ~s for channel ~s ~p", [URI, Name]),
            {error, invalid_mqtt_uri}
    end.
