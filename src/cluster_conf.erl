%%% -------------------------------------------------------------------
%%% Author  : skruger
%%% Description :
%%%
%%% Created : Feb 4, 2011
%%% -------------------------------------------------------------------
-module(cluster_conf).

-behaviour(gen_server).
%% --------------------------------------------------------------------
%% Include files
%% --------------------------------------------------------------------
-include("cluster_supervisor.hrl").
%% --------------------------------------------------------------------
%% External exports
-export([start_link/0,start_link/1,get/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {config_terms}).

%% ====================================================================
%% External functions
%% ====================================================================

get(Key,Default) ->
	try
		gen_server:call(?MODULE,{get,Key,Default})
	catch
		_:Err ->
			error_logger:error_msg("~p:get() error: ~p", [?MODULE,Err]),
			Default
	end.

%% ====================================================================
%% Server functions
%% ====================================================================

start_link() ->
	start_link(get_clusterconfig()).

start_link(Config) ->
	try
		case file:consult(Config) of
			{ok,Terms} ->
				gen_server:start_link({local,?MODULE},?MODULE,#state{config_terms=Terms},[]);
			Err ->
				error_logger:error_msg("~p:start_link(~p) failed with file:consult() error: ~p~n",[?MODULE,Config,Err]),
%% 				error_logger:error_msg("Could not read config from ~p.~n~p~n",[Config,Err]),
				Err
		end
	catch
%% 		_:{error,{LNum,erl_parse,Msg}} ->
%% 			error_logger:error_msg("~s on line ~p~n",[lists:flatten(Msg),LNum]),
%% 			{config_error,Config,Msg,LNum};
		_:CErr ->
			io:format("Could not read config from ~p.~n~p~n~n~n~n",[Config,CErr]),
			{startup_error,CErr}
	end.
get_clusterconfig() ->
	try
		case init:get_argument(clusterconfig) of
			{ok,[[Cfg|_]|_]} ->
				string:strip(Cfg,both,$");
			_ ->
				none
		end
	catch
		_:Err ->
			error_logger:error_msg("Error reading proxy config in get_proxyconfig(): ~p~n",[Err]),
			none
	end.

%% --------------------------------------------------------------------
%% Function: init/1
%% Description: Initiates the server
%% Returns: {ok, State}          |
%%          {ok, State, Timeout} |
%%          ignore               |
%%          {stop, Reason}
%% --------------------------------------------------------------------
init(State) ->
    {ok,State}.

%% --------------------------------------------------------------------
%% Function: handle_call/3
%% Description: Handling call messages
%% Returns: {reply, Reply, State}          |
%%          {reply, Reply, State, Timeout} |
%%          {noreply, State}               |
%%          {noreply, State, Timeout}      |
%%          {stop, Reason, Reply, State}   | (terminate/2 is called)
%%          {stop, Reason, State}            (terminate/2 is called)
%% --------------------------------------------------------------------
handle_call({get,Key,Def},_From,State) ->
	R = proplists:get_value(Key,State#state.config_terms,Def),
	{reply,R,State};
handle_call({get_callbacks,Type},_From,State) ->
	CallBacks = 
	lists:filter(fun(CB) -> case CB of
								#cluster_supervisor_callback{type=Type} -> true;
								_ -> false end end,application:get_env(cluster_supervisor,callbacks)),
	{reply,CallBacks,State};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%% --------------------------------------------------------------------
%% Function: handle_cast/2
%% Description: Handling cast messages
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%% --------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%% --------------------------------------------------------------------
%% Function: handle_info/2
%% Description: Handling all non call/cast messages
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%% --------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%% --------------------------------------------------------------------
%% Function: terminate/2
%% Description: Shutdown the server
%% Returns: any (ignored by gen_server)
%% --------------------------------------------------------------------
terminate(Reason, State) ->
    ok.

%% --------------------------------------------------------------------
%% Func: code_change/3
%% Purpose: Convert process state when code is changed
%% Returns: {ok, NewState}
%% --------------------------------------------------------------------
code_change(OldVsn, State, Extra) ->
    {ok, State}.

%% --------------------------------------------------------------------
%%% Internal functions
%% --------------------------------------------------------------------

