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
-export([get_name/1,start_link/1,discover_peers/1,force_election/1,stop_local/1,get_master/1,add_childspec/3,get_children/1,start_cluster/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {name,cluster_peers,is_master,master_node,peer_monitors,child_monitors}).

%% ====================================================================
%% External functions
%% ====================================================================

start_cluster(Name) ->
	AChild = {get_name(Name),{cluster_supervisor,start_link,[Name]},
	      permanent,2000,worker,[]},
	supervisor:start_child(cluster_supervisor_sup,AChild).
    

start_link(Name) ->
	PName = get_name(Name),
	gen_server:start_link({local,PName},?MODULE,[Name],[]).

stop_local(Name) ->
	PName = get_name(Name),
	gen_server:cast(PName,{?MODULE,exit}).

get_name(Name) ->
	list_to_atom(atom_to_list(?MODULE)++"_"++atom_to_list(Name)).

get_table_name(Name) ->
	get_name(Name).
%% 	list_to_atom("cluster_supervisor_childspec_"++atom_to_list(Name)).

get_children(Name) ->
	gen_server:call({global,get_name(Name)},get_children).

%% ====================================================================
%% Server functions
%% ====================================================================

get_master(Name) ->
	gen_server:call({global,get_name(Name)},get_master).

force_election(Name) ->
	gen_server:cast(get_name(Name),elect_master).

add_childspec(Name,Sup,CSpec) ->
	gen_server:call({global,get_name(Name)},{add_childspec,Sup,CSpec}).

%% --------------------------------------------------------------------
%% Function: init/1
%% Description: Initiates the server
%% Returns: {ok, State}          |
%%          {ok, State, Timeout} |
%%          ignore               |
%%          {stop, Reason}
%% --------------------------------------------------------------------
init([Name]) ->
%% 	error_logger:info_msg("~p starting on ~p~n",[get_name(Name),node()]),
	mnesia:create_table(get_table_name(Name),[{record_name,cluster_supervisor_childspec},{attributes,record_info(fields,cluster_supervisor_childspec)}]),
	mnesia:change_table_copy_type(get_table_name(Name),node(),disc_copies),
	lists:foreach(fun(Node) ->
						  gen_server:cast({get_name(Name),Node},elect_master)
				  end,nodes()),
	erlang:send_after(1000,self(),force_election),
	{ok, #state{name=Name,cluster_peers=[],is_master=false,child_monitors=[],peer_monitors=[]}}.

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
handle_call(get_children,_From,State) ->
	Name = State#state.name,
	{reply,do_get_children(Name),State};
handle_call({add_childspec,Sup,CSpec},_From,State) ->
	[ChildName|_] = tuple_to_list(CSpec),
	Rec = #cluster_supervisor_childspec{name={State#state.name,ChildName},supervisor=Sup,child_spec=CSpec},
	case mnesia:transaction(fun() -> mnesia:write(get_table_name(State#state.name),Rec,write) end) of
		{atomic,Ret} ->
			{reply,Ret,State};
		Other ->
			{reply,Other,State}
	end;
handle_call(get_master,_From,State) ->
	{reply,State#state.master_node,State};
handle_call({?MODULE,ping},_From,State) ->
	{reply,pong,State};
handle_call({new_master,Node},_From,State) ->
	{reply,ok,State#state{is_master=false,master_node=Node}};
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
handle_cast(elect_master,State) ->
	PName = get_name(State#state.name),
	Peers = discover_peers(State#state.name),
	[NewMaster|_] = lists:sort([node()|Peers]),
%% 	error_logger:info_msg("NewMaster=~p.  Peers=~p~n",[NewMaster,Peers]),
	gen_server:cast(self(),update_peer_monitors),
	if NewMaster == node() ->
		   global:re_register_name(PName,self()),
		   lists:foreach(fun(N) ->
								 gen_server:call({PName,N},{new_master,NewMaster})
						 end,Peers),
%% 		   error_logger:info_msg("~p elected self as master for ~p~n",[node(),PName]),
		   gen_server:cast(self(),check_children),
		   {noreply,State#state{cluster_peers=Peers,is_master=true,master_node=node()}};
	   true ->
		   gen_server:cast({PName,NewMaster},elect_master),
%% 		   error_logger:info_msg("~p not master in ~p election.~n",[node(),PName]),
		   {noreply,State#state{cluster_peers=Peers,is_master=false,master_node=undefined}}
	end;
handle_cast(update_peer_monitors,State) ->
%% 	error_logger:info_msg("Peers: ~p~n",[State#state.cluster_peers]),
	lists:foreach(fun(M) -> erlang:demonitor(M) end,State#state.peer_monitors),
	Mon = lists:map(fun(N) -> erlang:monitor(process,{get_name(State#state.name),N}) end,State#state.cluster_peers),
%% 	error_logger:info_msg("Update monitors: ~p~n",[Mon]),
	{noreply,State#state{peer_monitors=Mon}};


%%% Child health support

handle_cast(update_child_monitors,State) when State#state.is_master ->
	lists:foreach(fun(M) -> 
						  erlang:demonitor(M) 
				  end,State#state.child_monitors),
	Children = do_get_children(State#state.name),
	lists:foreach(fun(#cluster_supervisor_childspec{name={_,N},node=Node,supervisor=Sup}) ->
						  case supervisor_child({Sup,Node},N) of
							  [{_,undefined,_,_}|_] ->
%% 								  error_logger:info_msg("Child ~p not running in ~p ~p~n",[N,?MODULE,State#state.name]),
								  ok;
							  [{_,Pid,_,_}|_] ->
								  gen_server:cast(self(),{add_child_monitor,Pid})
						  end
				  end,Children),
	{noreply,State};
handle_cast(update_child_monitors,State) ->
	lists:foreach(fun(M) -> 
						  erlang:demonitor(M) 
				  end,State#state.child_monitors),
	{noreply,State#state{child_monitors=[]}};

handle_cast(check_children,State) when State#state.is_master ->
	lists:foreach(fun(CMon) ->
						  erlang:demonitor(CMon) end,State#state.child_monitors),
	lists:foreach(fun(Child) ->
						  gen_server:cast(self(),{check_child,Child})
				  end,do_get_children(State#state.name)),
	{noreply,State#state{child_monitors=[]}};
handle_cast(check_children,State) ->
%% 	?WARN_MSG("Check children called on non-master for group ~p.~n",[State#state.name]),
	if State#state.master_node == node() ->
%% 		   error_logger:error_msg("Node does not appear to be master of ~p, but has itself registered as the master node!  Forcing election!~n",[State#state.name]),
		   gen_server:cast(self(),elect_master);
	   true ->
		   gen_server:cast({get_name(State#state.name),State#state.master_node},check_children)
	end,
	{noreply,State};
handle_cast({check_child,#cluster_supervisor_childspec{supervisor=Sup,child_spec=CSpec}=Child},State) ->
%% 	error_logger:info_msg("Checking child: ~p~n",[Child]),
	[CName|_] = tuple_to_list(CSpec),
%% 	error_logger:info_msg("find_running_child(~p,~p,~p)~n",[CName,Sup,[node()|State#state.cluster_peers]]),
	case find_running_child(CName,Sup,[node()|State#state.cluster_peers]) of
		[] -> 
			gen_server:cast(self(),{start_child,Child});
		[{Node,{Id,undefined,_,_}}|_] ->
%% 			error_logger:info_msg("Child ~p has undefined pid.  Restarting manually.~n",[Id]),
			supervisor:delete_child({Sup,Node},Id),
			gen_server:cast(self(),{start_child,Child});
		[{Node,{_Name,Pid,_,_}}|_] ->
			mnesia:transaction(fun() -> mnesia:write(get_table_name(State#state.name),Child#cluster_supervisor_childspec{node=Node},write) end),
			gen_server:cast(self(),{add_child_monitor,Pid}),
%% 			error_logger:info_msg("Found child ~p running on node ~p with pid ~p~n",[CName,Node,Pid]),
			ok;
		FoundChild ->
			error_logger:warn_msg("find_running_child() returned invalid data! -> ~p~n",[FoundChild]),
			ok
	end,
	{noreply,State};
handle_cast({start_child,#cluster_supervisor_childspec{name={_,CName},supervisor=Sup,child_spec=Spec}=Child},State) ->
	StartNode = select_start_host(State#state.name),
%% 	error_logger:info_msg("Child not running (~p).  Starting on ~p.",[CName,StartNode]),
	mnesia:transaction(fun() -> mnesia:write(get_table_name(State#state.name),Child#cluster_supervisor_childspec{node=StartNode},write) end),
	case supervisor:start_child({Sup,StartNode},Spec) of
		{ok,Pid} ->
			gen_server:cast(self(),{add_child_monitor,Pid});
		{ok,Pid,_} ->
			gen_server:cast(self(),{add_child_monitor,Pid});
		{error,{{already_started,Pid},_}} ->
			exit(Pid,normal),
			error_logger:warning_msg("Discovered already running child pid!~nsupervisor:start_child({~p,~p},~p)",[Sup,StartNode,Spec]);
		{error,Err} ->
			error_logger:error_msg("Tried starting child ~p with error: ~p~n",[CName,Err])
	end,
	{noreply,State};

handle_cast({add_child_monitor,Pid},State) ->
%% 	error_logger:info_msg("Adding monitor for pid: ~p~n",[Pid]),
	{noreply,State#state{child_monitors=[erlang:monitor(process,Pid)]}};
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
handle_info(force_election,State) ->
	gen_server:cast(self(),elect_master),
	{noreply,State};
handle_info(delay_check_children,State) ->
	gen_server:cast(self(),check_children),
	{noreply,State};
handle_info({'DOWN',MonRef,process,_Proc,_Info}=_Msg,State) ->
	case lists:member(MonRef,State#state.child_monitors) of
		true ->
			error_logger:info_msg("Monitored child node went down in cluster ~p.~n",[State#state.name]),
			%% Delay the check_children call to give supervisors a chance to restart processes.
			erlang:send_after(2000,self(),delay_check_children);
		false ->
			ok
	end,
	case lists:member(MonRef,State#state.peer_monitors) of
		true ->
			error_logger:info_msg("Monitored peer node went down in cluster ~p.~n",[State#state.name]),
			gen_server:cast(self(),force_election);
		false ->
			ok
	end,
	{noreply,State};
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

	
	
do_get_children(Name) ->
	F = fun() ->
				Match = #cluster_supervisor_childspec{name={Name,'$1'},_='_'},
				lists:map(fun(C) -> [Ret|_] = mnesia:read(get_table_name(Name),{Name,C}),Ret end,
						  mnesia:select(get_table_name(Name),[{Match,[],['$1']}]))
%% 				mnesia:select(cluster_supervisor_childspec,[{Match,[],['$1']}])
		end,
	case mnesia:transaction(F) of
		{atomic,R} -> R;
		{aborted,Err} -> {error,Err}
	end.

supervisor_child(SupRef,ChildID) ->
	WhichChildren = supervisor:which_children(SupRef),
%% 	error_logger:info_msg("Finding child ~p with supervisor ~p~n~p~n",[ChildID,SupRef,WhichChildren]),
	lists:filter(fun(X) ->
						 case X of
							 {ChildID1,_,_,_} when ChildID1 == ChildID ->
								 true;
							 _ -> false
						 end end,WhichChildren).

find_running_child(Child,SupName,Peers) ->
%% 	error_logger:info_msg("Finding running child ~p~n",[Child]),
	ChildList = lists:map(fun(N) -> 
								  case supervisor_child({SupName,N},Child) of
									  [C1|_] -> {N,C1};
									  _ -> []
								  end
						  end, Peers),
%% 	error_logger:info_msg("ChildList: ~p~n",[ChildList]),
	lists:filter(fun(C) ->
						 case C of
%% 							 error_logger:info_msg("Child: ~p~nSupName: ~p~nC = ~p~n",[Child,SupName,C])
							 {_,{_,_,_,_}} -> true;
				 			 _ -> false
						 end
				 end,ChildList).

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

select_start_host(Name) ->
	AllNodes = [node()|discover_peers(Name)],
	Num = trunc((random:uniform()*65536)) rem length(AllNodes),
	lists:nth(Num+1,AllNodes).