%%% -------------------------------------------------------------------
%%% Author  : skruger
%%% Description :
%%%
%%% Created : Jan 7, 2011
%%% -------------------------------------------------------------------
-module(cluster_supervisor).

-behaviour(gen_server).
%% --------------------------------------------------------------------
%% Include files
%% --------------------------------------------------------------------
-include("cluster_supervisor.hrl").
%% --------------------------------------------------------------------
%% External exports
-export([get_name/1,start_link/1,discover_peers/1]).

-export([get_quorum/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {name,cluster_peers,is_master,master_node,peer_monitors,child_monitors,quorum}).

%% ====================================================================
%% External functions
%% ====================================================================

start_link(Name) ->
	PName = get_name(Name),
	IdLock = {PName,self()},
	global:trans(IdLock,
				 fun() ->
						 case global:whereis_name(PName) of
							 undefined ->
						 		gen_server:start_link({global,PName},?MODULE,[Name],[]); 
							 Pid -> 
								 {ok,Pid} 
						 end end).

get_name(Name) ->
	list_to_atom(atom_to_list(?MODULE)++"_"++atom_to_list(Name)).


%% ====================================================================
%% Server functions
%% ====================================================================

get_quorum(_Name) ->
	QuorumSize = cluster_conf:get(quorum,1),
	AllNodes = [node()|nodes()],
	ClusterNodes =
	lists:filter(fun(N) ->
						 cluster_supervisor_local:ping({cluster_supervisor_local,N}) == pong
				 end,AllNodes),
%% 	error_logger:error_msg("ClusterNodes=~p~n",[ClusterNodes]),
	case length(ClusterNodes) of
		Count when Count >= QuorumSize ->
			true;
		Count ->
			error_logger:error_msg("Unable to get quorum!  ~p members needed, ~p members active.~n",[QuorumSize,Count]),
			false
	end.

	%gen_server:call({global,get_name(Name)},get_quorum).


%% --------------------------------------------------------------------
%% Function: init/1
%% Description: Initiates the server
%% Returns: {ok, State}          |
%%          {ok, State, Timeout} |
%%          ignore               |
%%          {stop, Reason}
%% --------------------------------------------------------------------
init([Name]) ->
	{ok, #state{name=Name,cluster_peers=[],is_master=false,child_monitors=[],peer_monitors=[],quorum=true}}.

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
handle_call(get_quorum,_From,State) ->
	QuorumSize = cluster_conf:get(quorum,1),
	AllNodes = [node()|nodes()],
	ClusterNodes =
	lists:filter(fun(N) ->
						 cluster_supervisor_local:ping({cluster_supervisor_local,N}) == pong
				 end,AllNodes),
%% 	error_logger:error_msg("ClusterNodes=~p~n",[ClusterNodes]),
	case length(ClusterNodes) of
		Count when Count >= QuorumSize ->
			{reply,true,State#state{quorum=true}};
		Count ->
			if State#state.quorum == true ->
				   error_logger:error_msg("Unable to get quorum!  ~p members needed, ~p members active.~n",[QuorumSize,Count]);
			   true -> ok
			end,
			{reply,false,State#state{quorum=false}}
	end;

handle_call({?MODULE,ping},_From,State) ->
	{reply,pong,State};
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
handle_cast({?MODULE,exit},State) ->
	{stop,normal,State};
handle_cast(Msg, State) ->
	error_logger:info_msg("Unexpected cast ~p~n",[Msg]),
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
terminate(_Reason, _State) ->
    ok.

%% --------------------------------------------------------------------
%% Func: code_change/3
%% Purpose: Convert process state when code is changed
%% Returns: {ok, NewState}
%% --------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% --------------------------------------------------------------------
%%% Internal functions
%% --------------------------------------------------------------------

discover_peers(Name) ->
	lists:filter(fun(N) ->
						 try
							 net_adm:ping(N),
							 case gen_server:call({get_name(Name),N},{?MODULE,ping}) of
								 pong ->
									 true;
								 E -> 
									 error_logger:info_msg("E: ~p~n",[E]),
									 false
							 end
						 catch
							 _:_ER ->
								 false
						 end
				 end,nodes()).

