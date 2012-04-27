
-module(cluster_supervisor_callback).

%%
%% Include files
%%

-include("cluster_supervisor.hrl").

%%
%% Exported Functions
%%
-export([behaviour_info/1,add/3,remove/3]).

-export([vip_state/2]).

%%
%% API Functions
%%

behaviour_info(callbacks) ->
	[{vip_state,3}];
behaviour_info(_) ->
	undefined.

%% vip_state(State,VipAddr,ExtraArgs)

vip_state(State,VipAddr) ->
	CallBacks =
		case application:get_env(cluster_supervisor,callbacks) of
			{ok,CBList} ->
				lists:filter(fun(X) ->
									 case X of
										 #cluster_supervisor_callback{type=vip_state} ->
											 true;
										 _ ->
											 false
									 end
							 end,
							 CBList);
			_ -> []
		end,
	error_logger:warning_msg("Running ~p callbacks.~n~p~n",[length(CallBacks),CallBacks]),
	lists:foreach(fun(#cluster_supervisor_callback{module=Mod,extraargs=ExtraArgs}=CB) ->
						  try
							  erlang:apply(Mod,vip_state,[State,VipAddr,ExtraArgs])
						  catch
							  _:Err ->
								  error_logger:warning_msg("Error calling vip_state callback: "
														    "~p~n~p~n",
														   [CB,Err]),
								  ok
						  end
				  end,CallBacks).


%% Adding the same module twice results in replacing the previously added version.
add(Type,Module,ExtraArgs) ->
	CallBacks = 
		case application:get_env(cluster_supervisor,callbacks) of
			{ok,CBList} when is_list(CBList) ->
				lists:filter(fun(X) ->
									 case X of
										 #cluster_supervisor_callback{module=Module,
																	  type=Type} ->
											 false;
										 _ ->
											 true
									 end
							 end,
							 CBList);
			None -> 
				error_logger:error_msg("Replacing empty callback value: ~p~n",[None]),
				[]
		end,
%% 	error_logger:error_msg("Callbacks: ~p~n",[CallBacks]),
	CB = #cluster_supervisor_callback{type=Type,module=Module,extraargs=ExtraArgs},
	application:set_env(cluster_supervisor,callbacks,[CB|CallBacks]).
	
remove(Type,Module,ExtraArgs) ->
	CB = #cluster_supervisor_callback{type=Type,module=Module,extraargs=ExtraArgs},
	case application:get_env(cluster_supervisor,callbacks) of
		{ok,CBList} when is_list(CBList) ->
			NewCBList = 
			lists:filter(fun(This) ->
								 case This of
									 CB -> false;
									 _ -> true
								 end end, CBList),
			application:set_env(cluster_supervisor,callbacks,NewCBList);
		_ -> ok
	end.




%%
%% Local Functions
%%

