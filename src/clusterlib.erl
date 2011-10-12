-module(clusterlib).

%%
%% Include files
%%

%%
%% Exported Functions
%%
-export([inet_parse/1,inet_version/1]).

%%
%% API Functions
%%

inet_parse({ip,IP}) ->
	inet_parse(IP);
inet_parse({_,_,_,_,_,_,_,_}=IP) ->
	IP;
inet_parse({_,_,_,_} = IP) ->
	IP;
inet_parse(IPStr) when is_list(IPStr) ->
	case inet_parse:address(IPStr) of
		{ok,IP} ->
			IP;
		_ ->
			error_logger:error_msg("Invalid IP format: ~p~n~p~n",[IPStr,erlang:get_stacktrace()]),
			throw(invalid_ip)
	end.

inet_version({ip,IP}) ->
	inet_version(IP);
inet_version({_,_,_,_}) ->
	inet;
inet_version({_,_,_,_,_,_,_,_}) ->
	inet6.

%%
%% Local Functions
%%

