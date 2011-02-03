

-record(cluster_supervisor_childspec,{name,node,supervisor,child_spec}).


%% -define(CRITICAL(X,Y), surrogate_log:append(0,?MODULE,lists:flatten(io_lib:format(X,Y)))).
%% -define(ERROR_MSG(X,Y), surrogate_log:append(1,?MODULE,lists:flatten(io_lib:format(X,Y)))).
%% -define(WARN_MSG(X,Y), surrogate_log:append(2,?MODULE,lists:flatten(io_lib:format(X,Y)))).
%% -define(INFO_MSG(X,Y), surrogate_log:append(3,?MODULE,lists:flatten(io_lib:format(X,Y)))).
%% -define(DEBUG_MSG(X,Y), surrogate_log:append(4,?MODULE,lists:flatten(io_lib:format(X,Y)))).
