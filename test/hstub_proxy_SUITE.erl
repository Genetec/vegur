-module(hstub_proxy_SUITE).
-compile(export_all).
-include_lib("common_test/include/ct.hrl").

%%%===================================================================
%%% Common Test callbacks
%%%===================================================================

all() ->
    [{group, hstub_proxy_headers}
    ].

groups() ->
    [
     {hstub_proxy_headers, [], [request_id
                                ,forwarded_for
                                ,via
                               ]}
    ].

init_per_suite(Config) ->
    {ok, Cowboy} = application:ensure_all_started(cowboy),
    {ok, Inets} = application:ensure_all_started(inets),
    {ok, Meck} = application:ensure_all_started(meck),
    application:load(hstub),
    HstubPort = 9333,
    DynoPort = 9555,
    Mocked = mock_through(DynoPort),
    application:set_env(hstub, http_listen_port, HstubPort),
    {ok, HstubStarted} = application:ensure_all_started(hstub),
    [{started, Cowboy++Inets++HstubStarted++Meck},
     {mocked, Mocked},
     {hstub_port, HstubPort},
     {dyno_port, DynoPort}| Config].

end_per_suite(Config) ->
    [meck:unload(M) || M <- ?config(mocked, Config)],
    Config.

init_per_group(_, Config) ->
    Config.

end_per_group(_GroupName, Config) ->
    Config.

init_per_testcase(_TestCase, Config) ->
    DynoPort = ?config(dyno_port, Config),
    Self = self(),
    Dyno = start_dyno(DynoPort, [{in_handle, fun(Req) ->
                                                     Self ! {req, Req},
                                                     Req
                                             end}]),
    [{dyno, Dyno} | Config].

end_per_testcase(_TestCase, Config) ->
    stop_dyno(),
    Config.

%%%===================================================================
%%% Test cases
%%%===================================================================
request_id(Config) ->
    Port = ?config(hstub_port, Config),
    Url = "http://127.0.0.1:" ++ integer_to_list(Port),
    {ok, {{_, 204, _}, _, _}} = httpc:request(get, {Url, [{"host", "localhost"}]}, [], []),
    receive
        {req, Req} ->
            {RequestId, _} = cowboy_req:header(<<"request-id">>, Req),
            valid = erequest_id:validate(RequestId, hstub_app:config(request_id_max_size))
    after 5000 ->
            throw(timeout)
    end,
    {ok, {{_, 204, _}, _, _}} = httpc:request(get, {Url, [{"host", "localhost"},
                                                          {"request-id", "testid"}]}, [], []),
    receive
        {req, Req1} ->
            {<<"testid">>, _} = cowboy_req:header(<<"request-id">>, Req1)
    after 5000 ->
            throw(timeout)
    end,
    {ok, {{_, 204, _}, _, _}} = httpc:request(get, {Url, [{"host", "localhost"},
                                                          {"request-id", "testid??"}]}, [], []),
    receive
        {req, Req2} ->
            {RequestId1, _} = cowboy_req:header(<<"request-id">>, Req2),
            error_logger:info_msg("RequestId ~p", [RequestId1]),
            true = RequestId1 /= <<"testid??">>,
            valid = erequest_id:validate(RequestId1, hstub_app:config(request_id_max_size))
    after 5000 ->
            throw(timeout)
    end,
    Config.

forwarded_for(Config) ->
    Port = ?config(hstub_port, Config),
    Url = "http://127.0.0.1:" ++ integer_to_list(Port),
    {ok, {{_, 204, _}, _, _}} = httpc:request(get, {Url, [{"host", "localhost:"++integer_to_list(Port)}]}, [], []),
    receive
        {req, Req} ->
            {<<"127.0.0.1">>, _} = cowboy_req:header(<<"x-forwarded-for">>, Req),
            {DestPort, _} = cowboy_req:header(<<"x-forwarded-port">>, Req),
            Port = list_to_integer(binary_to_list(DestPort))
    after 5000 ->
            throw(timeout)
    end,
    {ok, {{_, 204, _}, _, _}} = httpc:request(get, {Url, [{"host", "localhost"},
                                                          {"x-forwarded-for", "10.0.0.1"}]}, [], []),
    receive
        {req, Req1} ->
            {<<"10.0.0.1, 127.0.0.1">>, _} = cowboy_req:header(<<"x-forwarded-for">>, Req1),
            {<<"80">>, _} = cowboy_req:header(<<"x-forwarded-port">>, Req1),
            {<<"http">>, _} = cowboy_req:header(<<"x-forwarded-proto">>, Req1)
    after 5000 ->
            throw(timeout)
    end,
    {ok, {{_, 204, _}, _, _}} = httpc:request(get, {Url, [{"host", "localhost:443"}]}, [], []),
    receive
        {req, Req2} ->
            {<<"443">>, _} = cowboy_req:header(<<"x-forwarded-port">>, Req2),
            {<<"https">>, _} = cowboy_req:header(<<"x-forwarded-proto">>, Req2)
    after 5000 ->
            throw(timeout)
    end,
    Config.

via(Config) ->
    Port = ?config(hstub_port, Config),
    Url = "http://127.0.0.1:" ++ integer_to_list(Port),
    {ok, {{_, 204, _}, _, _}} = httpc:request(get, {Url, [{"host", "localhost"}]}, [], []),
    receive
        {req, Req} ->
            {<<"hstub">>, _} = cowboy_req:header(<<"via">>, Req)
    after 5000 ->
            throw(timeout)
    end,
    {ok, {{_, 204, _}, _, _}} = httpc:request(get, {Url, [{"host", "localhost"},
                                                          {"via", "happyproxy"}]}, [], []),
    receive
        {req, Req1} ->
            {<<"happyproxy, hstub">>, _} = cowboy_req:header(<<"via">>, Req1)
    after 5000 ->
            throw(timeout)
    end,
    Config.

%% Helpers
start_dyno(Port, Opts) ->
    {ok, Pid} = hstub_dyno:start(Port, Opts),
    Pid.

stop_dyno() ->
    hstub_dyno:stop().

mock_through(Port) ->
    meck:new(hstub_lookup, [no_link, passthrough]),
    meck:expect(hstub_lookup, lookup_domain,
                fun(_) ->
                        {ok, test_domain}
                end),
    meck:expect(hstub_lookup, lookup_service,
                fun(_) ->
                        {route, test_route}
                end),
    meck:new(hstub_domains, [no_link, passthrough]),
    meck:expect(hstub_domains, in_maintenance_mode, fun(_) -> false end),
    meck:new(hstub_service, [no_link, passthrough]),
    meck:expect(hstub_service, backend,
                fun(_) ->
                        {{127,0,0,1}, Port}
                end),
    [hstub_lookup, hstub_domains, hstub_service].