-module(router_device_api).

-export([
         init/1,
         get_device/4,
         handle_data/2,
         report_status/2
        ]).

-define(API_MOD, router_device_api_module).

-spec init(any()) -> ok.
init(Args) ->
    {ok, Mod} = application:get_env(router, ?API_MOD),
    Mod:init(Args).

-spec get_device(binary(), binary(), binary(), binary()) -> {ok, router_device:device(), binary()} | {error, any()}.
get_device(DevEui, AppEui, Msg, MIC) ->
    {ok, Mod} = application:get_env(router, ?API_MOD),
    case Mod:get_devices(DevEui, AppEui) of
        [] -> {error, api_not_found};
        KeysAndDevices -> find_device(Msg, MIC, KeysAndDevices)
    end.

-spec handle_data(router_device:device(), map()) -> ok.
handle_data(Device, Map) ->
    {ok, Mod} = application:get_env(router, ?API_MOD),
    Mod:handle_data(Device, Map).

-spec report_status(router_device:device(), map()) -> ok.
report_status(Device, Map) ->
    {ok, Mod} = application:get_env(router, ?API_MOD),
    Mod:report_status(Device, Map).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec find_device(binary(), binary(), [{binary(), router_device:device()}]) -> {ok, router_device:device(), binary()} | {error, not_found}.
find_device(_Msg, _MIC, []) ->
    {error, not_found};
find_device(Msg, MIC, [{AppKey, Device}|T]) ->
    case crypto:cmac(aes_cbc128, AppKey, Msg, 4) of
        MIC ->
            {ok, Device, AppKey};
        _ ->
            find_device(Msg, MIC, T)
    end.
