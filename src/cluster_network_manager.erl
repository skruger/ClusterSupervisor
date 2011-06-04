%%% -------------------------------------------------------------------
%%% Author  : skruger
%%% Description :
%%%
%%% Created : Jan 9, 2011
%%% -------------------------------------------------------------------
-module(cluster_network_manager).

-behaviour(gen_server).
%% --------------------------------------------------------------------
%% Include files
%% --------------------------------------------------------------------
-include("cluster_supervisor.hrl").
%% --------------------------------------------------------------------
%% External exports
-export([get_interfaces/0,get_interface_addr/1,get_interface_proplist/1,get_interface_proplist/0,discover_node_interfaces/1,find_alias_node/1]).

-export([ip_tuple_to_list/1,ip_list_to_tuple/1]).
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {}).


%% ====================================================================
%% External functions
%% ====================================================================

ip_list_to_tuple(Ip) ->
	try
		DigitList = 
			lists:map(fun(D) ->
							  list_to_integer(D)
					  end,string:tokens(Ip,".")),
		case DigitList of
			List when is_list(List) and (length(List) == 4) ->
				{ip,list_to_tuple(List)};
			_ ->
				{error,badformat}
		end
	catch
		_:Err ->
			{error,Err}
	end.

ip_tuple_to_list({ip,IP}) ->
	lists:flatten(io_lib:format("~p.~p.~p.~p",tuple_to_list(IP))).


discover_node_interfaces(local) ->
	discover_node_interfaces(node());
discover_node_interfaces(Node) ->
	try
		% Use rpc call because gen_server instance of this module may not be running when
		% trying to find interfaces to shutdown.
		%gen_server:call({?MODULE,Node},get_interfaces)
		rpc:call(Node,?MODULE,get_interface_proplist,[],1000)
	catch
		_:Err ->
			error_logger:error_msg("Error when discovering node interfaces.  ~p~n",[Err]),
			[]
	end.

find_alias_node(Address) ->
	Interfaces = 
		lists:flatten(
		  lists:map(fun(N) ->
							try
								discover_node_interfaces(N)
							catch
								_:Err ->
									error_logger:error_msg("Error discovering interfaces on node: ~p~n~p~n",[N,Err]),
									[]
							end
					end,[node()|nodes()])),
%% 	error_logger:info_msg("Interfaces: ~p~n",[Interfaces]),
	lists:filter(fun(IntInfo) ->
						 case IntInfo of
							 #network_interfaces{address=Address} ->
								 true;
							 _ -> false
						 end end,Interfaces).
	

%% ====================================================================
%% Server functions
%% ====================================================================

start_link() ->
	gen_server:start_link({local,?MODULE},?MODULE,[],[]).

%% --------------------------------------------------------------------
%% Function: init/1
%% Description: Initiates the server
%% Returns: {ok, State}          |
%%          {ok, State, Timeout} |
%%          ignore               |
%%          {stop, Reason}
%% --------------------------------------------------------------------
init([]) ->
	error_logger:info_msg("Starting ~p~n",[?MODULE]),
	mnesia:create_table(cluster_network_address,[{attributes,record_info(fields,cluster_network_address)}]),
	mnesia:change_table_copy_type(cluster_network_address,node(),disc_copies),
	mnesia:add_table_copy(cluster_network_address,node(),disc_copies),
	mnesia:create_table(cluster_network_vip,[{attributes,record_info(fields,cluster_network_vip)}]),
	mnesia:add_table_index(cluster_network_vip,interface),
	mnesia:change_table_copy_type(cluster_network_vip,node(),disc_copies),
	mnesia:add_table_copy(cluster_network_vip,node(),disc_copies),
%% 	spawn(cluster_vip_manager,register,[]),
%% 	cluster_vip_manager:register(),
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
handle_call(get_interfaces,_From,State) ->
	{reply,get_interface_proplist(),State};
handle_call(get_addrs,_From,State) ->
	{reply,get_addresses()++cluster_vip_manager:get_vips(),State};

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

get_interfaces() ->
	string:tokens(os:cmd("ifconfig -a -s |egrep \"(^eth|^bond)\" | cut -f 1 -d ' ' "),"\n").

get_interface_addr(Iface) ->
	Cmd = "ifconfig "++Iface++" |sed -n 's/.*inet *addr:\\([0-9\\.]*\\).*/\\1/p'",
	string:strip(os:cmd(Cmd),right,$\n).

get_interface_proplist() ->
	get_interface_proplist(get_interfaces()).

get_interface_proplist(Interfaces) ->
	lists:map(fun(Iface) ->
					  #network_interfaces{node=node(),interface=list_to_atom(Iface),
										  address=ip_list_to_tuple(get_interface_addr(Iface)),
										  alias=is_alias_interface(Iface)}
			  end,Interfaces).

is_alias_interface(Iface) ->
	case string:str(Iface,":") of
		0 ->
			false;
		_ ->
			true
	end.



get_addresses() ->
	F1 = fun() ->
				 lists:map(fun(C) -> [Ret|_] = mnesia:read(cluster_network_address,C),Ret end,
						   mnesia:all_keys(cluster_network_address))
		 end,
	case mnesia:transaction(F1) of
		{atomic,Ret} ->
			Ret;
		Err ->
			error_logger:error_msg("~p error: ~p~n",[Err]),
			[]
	end.

