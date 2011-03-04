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
-export([register/0,start_link/0]).

-export([add_vip/1,enable_vip/1,disable_vip/1,get_vips/0,get_vip_alias/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {check_timer}).

%% ====================================================================
%% External functions
%% ====================================================================

%%  Call on initial startup to make sure vip manager is running.
register() ->
	F1 = fun() ->
				 receive a -> a
				 after 2000 ->
				 
						 cluster_supervisor:add_childspec(vip,cluster_supervisor_sup,
														  {?MODULE,{?MODULE,start_link,[]},
														   permanent,5000,worker,[]}),
						 cluster_supervisor:force_election(vip)
				 end
		 end,
	spawn(F1).

start_link() ->
	gen_server:start_link({global,?MODULE},?MODULE,[],[]).

%% ====================================================================
%% Server functions
%% ====================================================================

add_vip({ip,_}=Addr) ->
	gen_server:call({global,?MODULE},{add_vip,Addr}).

enable_vip({ip,_}=Addr) ->
	gen_server:call({global,?MODULE},{enable_vip,Addr}).

disable_vip({ip,_}=Addr) ->
	gen_server:call({global,?MODULE},{disable_vip,Addr}).

%% --------------------------------------------------------------------
%% Function: init/1
%% Description: Initiates the server
%% Returns: {ok, State}          |
%%          {ok, State, Timeout} |
%%          ignore               |
%%          {stop, Reason}
%% --------------------------------------------------------------------
init([]) ->
	erlang:register(?MODULE,self()),
	self() ! check_vips_timer,
    {ok, #state{}}.

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
	NewVip = #cluster_network_vip{addr=IP,status=unconfigured},
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
handle_call({enable_vip,IP},From,State) ->
	handle_call({set_vip_status,IP,active},From,State);
handle_call({disable_vip,IP},From,State) ->
	handle_call({set_vip_status,IP,disabled},From,State);
handle_call({set_vip_status,IP,Status},_From,State) ->
	F1 = fun() ->
				 case mnesia:read(cluster_network_vip,IP) of
					 [#cluster_network_vip{addr=IP}=VIP|_] ->
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
		[#cluster_network_vip{status=disabled}=Vip|_] ->
			gen_server:cast(self(),{stop_vip,Vip});
		[#cluster_network_vip{status=active}=Vip|_] ->
			gen_server:cast(self(),{check_active_vip_details,Vip});
		[Vip|_] ->
		gen_server:cast(self(),{start_vip,Vip})
	end,
	{noreply,State};
handle_cast({start_vip,Vip},State) ->
	Addr = Vip#cluster_network_vip.addr,
	case cluster_network_manager:find_alias_node(Addr) of
		[#network_interfaces{interface=Int,node=Node}|_] ->
			NewVip = Vip#cluster_network_vip{status=active,interface=Int,node=Node},
			error_logger:warning_msg("Vip already found running!  Updating vip information.~nOld: ~p~nNew: ~p~n",[Vip,NewVip]),
			mnesia:transaction(fun() -> mnesia:write(NewVip) end),
			{noreply,State};
		_ ->
			%%NewVip = Vip#cluster_network_vip{status=active,interface=,node=Node},
			IfCfgCmd = cluster_conf:get(ifconfig_script,?DEFAULT_IFCFG),
			IfCfg = io_lib:format("~s ~s up ~s",[IfCfgCmd,get_vip_alias(Addr),cluster_network_manager:ip_tuple_to_list(Addr)]),
			Ret = os:cmd(IfCfg),
			error_logger:info_msg("ifcfg: ~p~nReturned:~n~p~n",[lists:flatten(IfCfg),Ret]),
			{noreply,State}
	end;
handle_cast({stop_vip,Vip},State) ->
	Addr = Vip#cluster_network_vip.addr,
	case cluster_network_manager:find_alias_node(Addr) of
		[#network_interfaces{interface=Iface}=VipRec|_] when VipRec#network_interfaces.node == node() ->
			IfCfgCmd = cluster_conf:get(ifconfig_script,?DEFAULT_IFCFG),
			IfCfg = io_lib:format("~s ~s down",[IfCfgCmd,Iface]),
			Ret = os:cmd(IfCfg),
			error_logger:error_msg("Stopping vip on current node: ~p~n~p~n~p~n",[Vip,lists:flatten(IfCfg),Ret]);
		_AliasNode ->
%% 			error_logger:info_msg("{stop_vip,~p}~nFound: ~p~n",[Vip,AliasNode]),
			ok
	end,
	{noreply,State};
handle_cast({check_active_vip_details,#cluster_network_vip{addr=Addr,interface=Int,node=Node}=Vip},State) ->
	case cluster_network_manager:find_alias_node(Addr) of
		[#network_interfaces{interface=Int,node=Node}|_] ->
			{noreply,State};
		[#network_interfaces{interface=NewInt,node=NewNode}|_] ->
			NewVip = Vip#cluster_network_vip{interface=NewInt,node=NewNode},
			error_logger:error_msg("Vip details didn't match!~nOld: ~p~nNew: ~p~n",[Vip,NewVip]),
			mnesia:transaction(fun() -> mnesia:write(NewVip) end),
			{noreply,State};
		Other ->
			error_logger:error_msg("Vip not found on any running nodes!  Trying to start!~nfind_alias_node() returned ~p~nVip: ~p~n",[Other,Vip]),
			gen_server:cast(self(),{start_vip,Vip}),
			{noreply,State}
	end;
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
	lists:foreach(fun(V) -> gen_server:cast(self(),{check_vip,V}) end,mnesia:dirty_all_keys(cluster_network_vip)),
	{noreply,State};
handle_info(Info, State) ->
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
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% --------------------------------------------------------------------
%%% Internal functions
%% --------------------------------------------------------------------

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
							