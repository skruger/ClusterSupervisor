%%% -------------------------------------------------------------------
%%% Author  : skruger
%%% Description :
%%%
%%% Created : Feb 3, 2011
%%% -------------------------------------------------------------------
-module(cluster_vip_manager).

-behaviour(gen_server).
%% --------------------------------------------------------------------
%% Include files
%% --------------------------------------------------------------------
-include("cluster_supervisor.hrl").
%% --------------------------------------------------------------------
%% External exports
-export([start_link/0]).

-export([add_vip/1,enable_vip/1,disable_vip/1,get_vips/0,get_vip_alias/1,status/0,start_vip_rpc/2,set_hostnodes/2,stop_local_vips/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {check_timer,ifconfig_script}).

%% ====================================================================
%% External functions
%% ====================================================================

start_link() ->
	IdLock = {?MODULE,self()},
	global:trans(IdLock,
				 fun() ->
						 case global:whereis_name(?MODULE) of
							 undefined ->
								 gen_server:start_link({global,?MODULE},?MODULE,[],[]);
							 Pid ->
								 erlang:link(Pid),
								 {ok,Pid}
						 end end).

%% ====================================================================
%% Server functions
%% ====================================================================

add_vip({ip,_}=Addr) ->
	gen_server:call({global,?MODULE},{add_vip,Addr}).

enable_vip({ip,_}=Addr) ->
	gen_server:call({global,?MODULE},{enable_vip,Addr}).

disable_vip({ip,_}=Addr) ->
	gen_server:call({global,?MODULE},{disable_vip,Addr}).

set_hostnodes({ip,_}=Addr,Nodes) ->
	gen_server:call({global,?MODULE},{set_hostnodes,Addr,Nodes}).

status() ->
	gen_server:call({global,?MODULE},{status}).

%% --------------------------------------------------------------------
%% Function: init/1
%% Description: Initiates the server
%% Returns: {ok, State}          |
%%          {ok, State, Timeout} |
%%          ignore               |
%%          {stop, Reason}
%% --------------------------------------------------------------------
init([]) ->
	process_flag(trap_exit, true),
	erlang:register(?MODULE,self()),
	self() ! check_vips_timer,
    {ok, #state{ifconfig_script=cluster_conf:get(ifconfig_script,?DEFAULT_IFCFG)}}.

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
handle_call({add_vip,IP},_From,State) ->
	NewVip = #cluster_network_vip{addr=IP,status=unconfigured,hostnodes=[]},
	F1 = fun() ->
				 case mnesia:read(cluster_network_vip,IP) of
					 [#cluster_network_vip{addr=IP}|_] ->
						 mnesia:abort(addrinuse);
					 _ ->
						 mnesia:write(NewVip)
				 end
		 end,
	case mnesia:transaction(F1) of
		{atomic,Res} ->
			{reply,Res,State};
		{aborted,Reason} ->
			{reply,{error,Reason},State};
		Error ->
			{reply,Error,State}
	end;
handle_call({set_hostnodes,IP,Nodes},_From,State) ->
	F1 = fun() ->
				 case mnesia:read(cluster_network_vip,IP) of
					[Vip|_] ->
						mnesia:write(Vip#cluster_network_vip{hostnodes=Nodes});
					_ ->
						mnesia:abort(novip)
				 end end,
	case mnesia:transaction(F1) of
		{atomic,Res} ->
			{reply,Res,State};
		{aborted,Reason} ->
			{reply,{error,Reason},State};
		Error ->
			{reply,Error,State}
	end;
handle_call({enable_vip,IP},From,State) ->
	handle_call({set_vip_status,IP,active},From,State);
handle_call({disable_vip,IP},From,State) ->
	handle_call({set_vip_status,IP,disabled},From,State);
handle_call({set_vip_status,IP,Status},_From,State) ->
	F1 = fun() ->
				 case mnesia:read(cluster_network_vip,IP) of
					 [#cluster_network_vip{addr=IP,node=Node}=VIP|_] ->
						 gen_server:cast({?MODULE,Node},{stop_vip,VIP,inet_version(IP)}),
						 mnesia:write(VIP#cluster_network_vip{status=Status});
					 _ -> mnesia:abort(invalid_vip)
				 end
		 end,
	case mnesia:transaction(F1) of
		{atomic,Res} ->
			{reply,Res,State};
		{aborted,Reason} ->
			{reply,{error,Reason},State};
		Error ->
			{reply,Error,State}
	end;
handle_call({status},_From,State) ->
	{reply,State,State};
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
handle_cast({check_vip,VipKey},State) ->
%%	error_logger:info_msg("Checking vip: ~p~n",[VipKey]),
	case mnesia:dirty_read(cluster_network_vip,VipKey) of
		[#cluster_network_vip{status=disabled,interface=undefined,node=undefined}|_] ->
			ok;
		[#cluster_network_vip{status=disabled,addr=Addr}=Vip|_] ->
			gen_server:cast(self(),{stop_vip,Vip,inet_version(Addr)});
%% 		[#cluster_network_vip{status=active}=Vip|_] ->
%% 			gen_server:cast(self(),{check_active_vip_details,Vip});
		[#cluster_network_vip{addr=_Addr}=Vip|_] ->
			gen_server:cast(self(),{check_active_vip_details,Vip})
	end,
	{noreply,State};
handle_cast({stop_vip,Vip,inet6},State) ->
	Addr = Vip#cluster_network_vip.addr,
	error_logger:error_msg("Can't stop inet6 vip: ~p~n",[Addr]),
	{noreply,State};
handle_cast({stop_vip,Vip,inet},State) ->
	Addr = Vip#cluster_network_vip.addr,
	case cluster_network_manager:find_alias_node(Addr) of
		[#network_interfaces{interface=Iface,node=Node}=VipRec|_] when VipRec#network_interfaces.node == node() ->
			IfCfgCmd = rpc:call(Node,cluster_conf,get,[ifconfig_script,?DEFAULT_IFCFG]),
%% 			IfCfgCmd = cluster_conf:get(),
%% 			Ret = os:cmd(IfCfg),
			IfCfg = io_lib:format("~s ~s down",[IfCfgCmd,Iface]),
			Ret = rpc:call(Node,os,cmd,[IfCfg]),
			cluster_supervisor_callback:vip_state({down,node(),Vip},Addr),
			error_logger:error_msg("Stopping vip on current node: ~p~n~p~n~p~n",[Vip,lists:flatten(IfCfg),Ret]);
		_AliasNode ->
%% 			error_logger:info_msg("{stop_vip,~p}~nFound: ~p~n",[Vip,AliasNode]),
			ok
	end,
	{noreply,State};
handle_cast({check_active_vip_details,#cluster_network_vip{addr=Addr}=Vip},State) when Vip#cluster_network_vip.hostnodes == [] ->
	error_logger:error_msg("Vip ~p does not have any candidate host nodes.~n",[Addr]),
	case cluster_network_manager:find_alias_node(Addr) of
		[#network_interfaces{node=Node}|_] ->
			error_logger:error_msg("Vip ~p found running on unauthorized node ~p!  Stopping.~n",[Addr,Node]),
			gen_server:cast(self(),{stop_vip,Vip,inet_version(Addr)});
		_ ->
			ok
	end,
	{noreply,State};
handle_cast({check_active_vip_details,#cluster_network_vip{addr=Addr,interface=Int,node=Node,hostnodes=HostNodes}=Vip},State) ->
	[PreferredNode|_] = HostNodes,
	case cluster_network_manager:find_alias_node(Addr) of
		[#network_interfaces{interface=Int,node=Node}|_] when Node /= PreferredNode ->
%% 			error_logger:info_msg("vip ~p is not running on its preferred node.~n",[Addr]),
			gen_server:cast(self(),{fix_vip_node,Vip,HostNodes}),
			{noreply,State};
		[#network_interfaces{interface=Int,node=Node}|_] ->
			{noreply,State};
		[#network_interfaces{interface=NewInt,node=NewNode}|_] ->
			NewVip = Vip#cluster_network_vip{interface=NewInt,node=NewNode},
			error_logger:error_msg("Vip details didn't match!~nOld: ~p~nNew: ~p~n",[Vip,NewVip]),
			mnesia:transaction(fun() -> mnesia:write(NewVip) end),
			{noreply,State};
		Other ->
			error_logger:error_msg("Vip not found on any running nodes!  Trying to start on ~p!~nfind_alias_node() returned ~p~nVip: ~p~n",[Node,Other,Vip]),
			_StartedNode = start_vip(Vip,inet_version(Addr),HostNodes),
			{noreply,State}
	end;
handle_cast({fix_vip_node,VIP,[TryNode|_R]},State) when VIP#cluster_network_vip.node == TryNode ->
	{noreply,State};
handle_cast({fix_vip_node,VIP,[TryNode|R]},State) ->
	case lists:any(fun(N) -> N == TryNode end, mnesia:system_info(running_db_nodes)) of
		true ->
			case cluster_supervisor_local:ping({cluster_supervisor_local,TryNode}) of
				pong ->
					gen_server:cast(self(),{stop_vip,VIP,inet_version(VIP#cluster_network_vip.addr)}),
					gen_server:cast(self(),{check_active_vip_details,VIP}),
					ok;
				_ ->
					% Trying next node in list.
					gen_server:cast(self(),{fix_vip_node,VIP,R})
			end;
		false ->
			% Trying next node in list.
			gen_server:cast(self(),{fix_vip_node,VIP,R})
	end,
%% 	error_logger:error_msg("Trying node: ~p~n",[TryNode]),
	{noreply,State};
handle_cast(stop_local_vips,State) ->
	try
		stop_local_vips()
	catch
		_:Err ->
			error_logger:error_msg("Error stopping local vips: ~n~p~n",[Err])
	end,
	{noreply,State};
handle_cast(Msg, State) ->
	error_logger:info_msg("Received unknown message: ~p~n",[Msg]),
    {noreply, State}.


%% --------------------------------------------------------------------
%% Function: handle_info/2
%% Description: Handling all non call/cast messages
%% Returns: {noreply, State}          |
%%          {noreply, State, Timeout} |
%%          {stop, Reason, State}            (terminate/2 is called)
%% --------------------------------------------------------------------
handle_info(check_vips_timer,State) ->
	self() ! check_vips,
	TRef = erlang:send_after(10000,self(),check_vips_timer),
	{noreply,State#state{check_timer=TRef}};
handle_info(check_vips,State) ->
%% 	error_logger:info_msg("Check vips.~n",[]),
	case cluster_supervisor:get_quorum(vip) of
		true ->
			lists:foreach(fun(V) -> gen_server:cast(self(),{check_vip,V}) end,mnesia:dirty_all_keys(cluster_network_vip));
		false ->
			gen_server:cast(self(),stop_local_vips)
	end,
	{noreply,State};
handle_info(_Info, State) ->
    {noreply, State}.

%% --------------------------------------------------------------------
%% Function: terminate/2
%% Description: Shutdown the server
%% Returns: any (ignored by gen_server)
%% --------------------------------------------------------------------
terminate(shutdown,_State) ->
	stop_local_vips(),
	ok;
terminate(Reason, _State) ->
	error_logger:info_msg("~p stopping for reason ~p.~n",[?MODULE,Reason]),
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

start_vip(_Vip,inet,undefined) ->
	{error,nonodes};
start_vip(_Vip,inet,[]) ->
	{error,nonodes};
start_vip(#cluster_network_vip{addr=Addr}=Vip,inet,[Node|RNodes]) ->
	case cluster_supervisor_local:ping({cluster_supervisor_local,Node}) of
		pong ->
			case catch rpc:call(Node,?MODULE,start_vip_rpc,[Vip,inet]) of
				ok ->
					Node;
				_ ->
					error_logger:warning_msg("Vip ~p unable to start on node ~p~n", [Addr,Node]),
					start_vip(Vip,inet,RNodes)
			end;
		_ ->
			start_vip(Vip,inet,RNodes)
	end.
				
		
start_vip_rpc(#cluster_network_vip{addr=Addr}=Vip,inet) ->
	IfCfgCmd = cluster_conf:get(ifconfig_script,?DEFAULT_IFCFG),
	IfCfg = io_lib:format("~s ~s up ~s",[IfCfgCmd,get_vip_alias(Addr),cluster_network_manager:ip_tuple_to_list(Addr)]),
	Ret = os:cmd(IfCfg),
	cluster_supervisor_callback:vip_state({up,node(),Vip},Addr),
	error_logger:error_msg("Starting vip on ~p: ~p~n~p~n~p~n",[node(),Vip,lists:flatten(IfCfg),Ret]),
	ok.

get_vips() ->
	F1 = fun() ->
				 lists:map(fun(C) -> [Ret|_] = mnesia:read(cluster_network_vip,C),Ret end,
						   mnesia:all_keys(cluster_network_vip))
		 end,
	case mnesia:transaction(F1) of
		{atomic,Ret} ->
			Ret;
		Err ->
			error_logger:error_msg("~p error: ~p~n",[Err]),
			[]
	end.

get_vip_alias_num({ip,{A,B,C,D}}) ->
	integer_to_list(A*16777216+B*65536+C*256+D).

get_vip_alias(IP) ->
	Num = get_vip_alias_num(IP),
	Iface =
	case cluster_conf:get(listen_interface,"eth0") of
		Int when is_atom(Int) -> atom_to_list(Int);
		Int -> Int
	end,
	Iface++":"++Num.
	
stop_local_vips() ->
	Interfaces = 
	lists:filter(fun(Int) -> Int#network_interfaces.alias end,cluster_network_manager:discover_node_interfaces(local)),
	lists:foreach(fun(IntRec) ->
						  Iface = IntRec#network_interfaces.interface,
						  try
							  [Vip|_] = mnesia:dirty_index_read(cluster_network_vip,Iface,#cluster_network_vip.interface),
							  cluster_supervisor_callback:vip_state({down,node(),Vip},Vip#cluster_network_vip.addr)
						  catch
							  _:_ ->
								  ok
						  end,
						  IfCfgCmd = cluster_conf:get(ifconfig_script,?DEFAULT_IFCFG),
						  IfCfg = io_lib:format("~s ~s down",[IfCfgCmd,Iface]),
						  Ret = os:cmd(IfCfg),
						  error_logger:error_msg("Stopping local vip: ~p~n~p~n~p~n",[IntRec,lists:flatten(IfCfg),Ret])
				  end,Interfaces),
	ok.

inet_version({ip,IP}) ->
	inet_version(IP);
inet_version({_,_,_,_}) ->
	inet;
inet_version({_,_,_,_,_,_,_,_}) ->
	inet6.