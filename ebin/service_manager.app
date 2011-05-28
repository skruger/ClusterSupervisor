{application, service_manager,
 [{description, "Service manager for managing services through the cluster_supervisor application."},
  {vsn, "0.1"},
  {modules, [ service_manager_app,service_manager_sup,service_manager]},
  {registered,[service_manager_sup ]},
  {applications, [kernel,stdlib,mnesia]},
  {mod, {service_manager_app,[]}},
  {start_phases,[]}
]}.
