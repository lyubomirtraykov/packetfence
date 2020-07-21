package pf::UnifiedApi;

=head1 NAME

pf::UnifiedApi - The base of the mojo app

=cut

=head1 DESCRIPTION

pf::UnifiedApi

=cut

use strict;
use warnings;
use JSON::MaybeXS qw();
{
   package JSON::PP::Boolean;
   sub clone {
       my $o = ${$_[0]};
       return bless (\$o, 'JSON::PP::Boolean');
   }
}

use Mojo::Base 'Mojolicious';
use pf::dal;
use pf::util qw(add_jitter);
use pf::file_paths qw($log_conf_dir);
use pf::SwitchFactory;
pf::SwitchFactory->preloadAllModules();
use MojoX::Log::Log4perl;
use pf::UnifiedApi::Controller;
use pf::I18N::pfappserver;
our $MAX_REQUEST_HANDLED = 2000;
our $REQUEST_HANDLED_JITTER = 500;

has commands => sub {
  my $commands = Mojolicious::Commands->new(app => shift);
  Scalar::Util::weaken $commands->{app};
  unshift @{$commands->namespaces}, 'pf::UnifiedApi::Command';
  return $commands;
};

has log => sub {
    return MojoX::Log::Log4perl->new("$log_conf_dir/pfperl-api.conf",5 * 60);
};

sub escape_char {
    my ($k) = @_;
    if ($k eq '2f' || $k eq '2F') {
        return "\%$k";
    }
    return chr(hex($k));
}

sub pf_unescape_path {
    my ($path) = @_;
    $path =~ s/\%([a-fA-F0-9]{2})/escape_char($1)/eg;
    return $path;
}

=head2 startup

Setting up routes

=cut

sub startup {
    my ($self) = @_;
    $self->controller_class('pf::UnifiedApi::Controller');
    $self->routes->namespaces(['pf::UnifiedApi::Controller', 'pf::UnifiedApi']);
    $self->hook(before_dispatch => \&before_dispatch_cb);
    $self->hook(after_dispatch => \&after_dispatch_cb);
    $self->hook(before_render => \&before_render_cb);
    $self->plugin('pf::UnifiedApi::Plugin::RestCrud');
#   $self->plugin('NYTProf' => {
#       nytprof => {
#           profiles_dir => "/usr/local/pf/var/nytprof",
#       },
#   });
    my $routes = $self->routes;
    $self->setup_api_v1_routes($routes->any("/api/v1")->name("api.v1"));
    $self->custom_startup_hook();
    $routes->any( '/*', sub {
        my ($c) = @_;
        return $c->unknown_action;
    });

    return;
}

=head2 before_render_cb

before_render_cb

=cut

sub before_render_cb {
    my ($self, $args) = @_;

    my $template = $args->{template} || '';
    if ($template =~ /^exception/) {
        $args->{json} = {message => $args->{exception} || 'Unknown error, check server side logs for details.'};
    }

    my $json = $args->{json};
    return unless $json;
    $json->{status} //= ($args->{status} // 200);
}

=head2 after_dispatch_cb

after_dispatch_cb

=cut

sub after_dispatch_cb {
    my ($c) = @_;
    eval {
        $c->audit_request if $c->can("audit_request");
    };

    if($@) {
        $c->log->error("Failed to audit request: $@");
    }

    my $app = $c->app;
    my $max = $app->{max_requests_handled} //= add_jitter( $MAX_REQUEST_HANDLED, $REQUEST_HANDLED_JITTER );
    if (++$app->{requests_handled} >= $max) {
        kill 'QUIT', $$;
    }
    return;
}

=head2 before_dispatch_cb

before_dispatch_cb

=cut

sub before_dispatch_cb {
    my ($c) = @_;
    # To allow dispatching with encoded slashes
    my $req = $c->req;
    my $headers = $req->headers;
    $req->default_charset('UTF-8');
    $c->stash(
        {
            path        => pf_unescape_path($req->url->path),
#            path        => $req->url->path,
            admin_roles => [
                split(
                    /\s*,\s*/,
                    $headers->header('X-PacketFence-Admin-Roles') // ''
                )
            ],
            languages => pf::I18N::pfappserver->languages_from_http_header(
                $headers->header('Accept-Language')
            ),
            current_user => $headers->header('X-PacketFence-Username')
        }
    );
    set_tenant_id($c)
}

sub setup_api_v1_routes {
    my ($self, $api_v1_route) = @_;
    $self->setup_api_v1_crud_routes($api_v1_route);
    $self->setup_api_v1_config_routes($api_v1_route->any("/config")->name("api.v1.Config"));
    $self->setup_api_v1_configurator_routes($api_v1_route->under("/configurator")->to(controller => "Configurator", action => "allowed")->name("api.v1.Configurator"));
    $self->setup_api_v1_fingerbank_routes($api_v1_route);
    $self->setup_api_v1_reports_routes($api_v1_route->any("/reports")->name("api.v1.Reports"));
    $self->setup_api_v1_dynamic_reports_routes($api_v1_route);
    $self->setup_api_v1_current_user_routes($api_v1_route);
    $self->setup_api_v1_services_routes($api_v1_route);
    $self->setup_api_v1_cluster_routes($api_v1_route);
    $self->setup_api_v1_authentication_routes($api_v1_route);
    $self->setup_api_v1_queues_routes($api_v1_route);
    $self->setup_api_v1_translations_routes($api_v1_route);
    $self->setup_api_v1_preferences_routes($api_v1_route);
    $self->setup_api_v1_system_services_routes($api_v1_route);
    $self->setup_api_v1_system_summary_route($api_v1_route);
    $self->setup_api_v1_emails_route($api_v1_route);
}

sub custom_startup_hook {

}

=head2 set_tenant_id

Set the tenant ID to the one specified in the header, or reset it to the default one if there is none

=cut

sub set_tenant_id {
    my ($c) = @_;
    my $tenant_id = $c->req->headers->header('X-PacketFence-Tenant-Id');
    if (defined $tenant_id) {
        unless (pf::dal->set_tenant($tenant_id)) {
            $c->render(json => { message => "Invalid tenant id provided $tenant_id"}, status => 404);
        }
    } else {
        pf::dal->reset_tenant();
    }
}

=head2 ReadonlyEndpoint

ReadonlyEndpoint

=cut

sub ReadonlyEndpoint {
    my ($model) = @_;
    return {
        controller => $model,
        collection => {
            http_methods => {
                'get'    => 'list',
            },
            subroutes => {
                map { $_ => { post => $_ } } qw(search)
            }
        },
        resource => {
            http_methods => {
                'get'    => 'get',
            },
        },
    },
}

=head2 setup_api_v1_crud_routes

setup_api_v1_crud_routes

=cut

sub setup_api_v1_crud_routes {
    my ($self, $root) = @_;
    $self->setup_api_v1_users_routes($root);
    $self->setup_api_v1_nodes_routes($root);
    $self->setup_api_v1_tenants_routes($root);
    $self->setup_api_v1_locationlogs_routes($root);
    $self->setup_api_v1_dhcp_option82s_routes($root);
    $self->setup_api_v1_auth_logs_routes($root);
    $self->setup_api_v1_radius_audit_logs_routes($root);
    $self->setup_api_v1_dns_audit_logs_routes($root);
    $self->setup_api_v1_admin_api_audit_logs_routes($root);
    $self->setup_api_v1_wrix_locations_routes($root);
    $self->setup_api_v1_security_events_routes($root);
    $self->setup_api_v1_sms_carriers_routes($root);
    $self->setup_api_v1_node_categories_routes($root);
    $self->setup_api_v1_classes_routes($root);
    $self->setup_api_v1_ip4logs_routes($root);
    $self->setup_api_v1_ip6logs_routes($root);
    return;
}

=head2 setup_api_v1_sms_carriers_routes

setup_api_v1_sms_carriers_routes

=cut

sub setup_api_v1_sms_carriers_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_crud_routes(
        $root,
        "SMSCarriers",
        "/sms_carriers",
        "/sms_carrier/#sms_carrier_id",
        "api.v1.SMSCarriers"
    );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_config_routes

setup api v1 config routes

=cut

sub setup_api_v1_config_routes {
    my ($self, $root) = @_;
    $self->setup_api_v1_config_admin_roles_routes($root);
    $self->setup_api_v1_config_bases_routes($root);
    $self->setup_api_v1_config_billing_tiers_routes($root);
    $self->setup_api_v1_config_certificates_routes($root);
    $self->setup_api_v1_config_connection_profiles_routes($root);
    $self->setup_api_v1_config_self_services_routes($root);
    $self->setup_api_v1_config_domains_routes($root);
    $self->setup_api_v1_config_filters_routes($root);
    $self->setup_api_v1_config_filter_engines_routes($root);
    $self->setup_api_v1_config_fingerbank_settings_routes($root);
    $self->setup_api_v1_config_firewalls_routes($root);
    $self->setup_api_v1_config_floating_devices_routes($root);
    $self->setup_api_v1_config_maintenance_tasks_routes($root);
    $self->setup_api_v1_config_network_behavior_policies_routes($root);
    $self->setup_api_v1_config_misc_routes($root);
    $self->setup_api_v1_config_interfaces_routes($root);
    $self->setup_api_v1_config_l2_networks_routes($root);
    $self->setup_api_v1_config_routed_networks_routes($root);
    $self->setup_api_v1_config_pki_providers_routes($root);
    $self->setup_api_v1_config_portal_modules_routes($root);
    $self->setup_api_v1_config_provisionings_routes($root);
    $self->setup_api_v1_config_radiusd_routes($root);
    $self->setup_api_v1_config_realms_routes($root);
    $self->setup_api_v1_config_roles_routes($root);
    $self->setup_api_v1_config_scans_routes($root);
    $self->setup_api_v1_config_security_events_routes($root);
    $self->setup_api_v1_config_sources_routes($root);
    $self->setup_api_v1_config_switches_routes($root);
    $self->setup_api_v1_config_switch_groups_routes($root);
    $self->setup_api_v1_config_syslog_forwarders_routes($root);
    $self->setup_api_v1_config_syslog_parsers_routes($root);
    $self->setup_api_v1_config_ssl_certificates_routes($root);
    $self->setup_api_v1_config_template_switches_routes($root);
    $self->setup_api_v1_config_system_routes($root);
    $self->setup_api_v1_config_traffic_shaping_policies_routes($root);
    $self->setup_api_v1_config_wmi_rules_routes($root);
    return;
}

=head2 setup_api_v1_config_misc_routes

setup_api_v1_config_misc_routes

=cut

sub setup_api_v1_config_misc_routes {
    my ($self, $root) = @_;
    $root->register_sub_action({ controller => 'Config', action => 'fix_permissions', method => 'POST' });
    $root->register_sub_action({ controller => 'Config', action => 'checkup', method => 'GET' });
    $root->register_sub_actions(
        {
            method     => 'POST',
            actions    => [qw(parse_condition flatten_condition)],
            controller => 'Config'
        }
    );
    return ;
}

=head2 setup_api_v1_current_user_routes

setup_api_v1_current_user_routes

=cut

sub setup_api_v1_current_user_routes {
    my ($self, $root) = @_;
    my $route = $root->any("/current_user")->to( controller => "CurrentUser" )->name("CurrentUser");
    $route->register_sub_actions(
        {
            actions => [
                qw(
                  allowed_user_unreg_date allowed_user_roles allowed_node_roles
                  allowed_user_access_levels allowed_user_actions allowed_user_access_durations
                )
            ],
            method => 'GET'
        }
    );
    return;
}

=head2 setup_api_v1_tenants_routes

setup_api_v1_tenants_routes

=cut

sub setup_api_v1_tenants_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_crud_routes(
        $root,
        "Tenants",
        "/tenants",
        "/tenant/#tenant_id",
    );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_locationlogs_routes

setup_api_v1_locationlogs_routes

=cut

sub setup_api_v1_locationlogs_routes {
    my ($self, $root) = @_;
    my $controller = "Locationlogs";
    my $name = $self->make_name_from_controller($root, $controller);
    my $collection_route = $root->any("/locationlogs")->to(controller => $controller)->name($name);

    $collection_route->register_sub_action({ action => 'list', path => '', method => 'GET' });
    $collection_route->register_sub_action({ action => 'search', method => 'POST' });
    $collection_route->register_sub_action({ action => 'ssids', method => 'GET' });

    return ($collection_route, undef);
}

=head2 setup_api_v1_dhcp_option82s_routes

setup_api_v1_dhcp_option82s_routes

=cut

sub setup_api_v1_dhcp_option82s_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_crud_routes(
        $root,
        "DhcpOption82s",
        "/dhcp_option82s",
        "/dhcp_option82/#dhcp_option82_id",
    );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_auth_logs_routes

setup_api_v1_auth_logs_routes

=cut

sub setup_api_v1_auth_logs_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_crud_routes(
        $root,
        "AuthLogs",
        "/auth_logs",
        "/auth_log/#auth_log_id",
    );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_radius_audit_logs_routes

setup_api_v1_radius_audit_logs_routes

=cut

sub setup_api_v1_radius_audit_logs_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_crud_routes(
        $root,
        "RadiusAuditLogs",
        "/radius_audit_logs",
        "/radius_audit_log/#radius_audit_log_id",
    );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_dns_audit_logs_routes

setup_api_v1_dns_audit_logs_routes

=cut

sub setup_api_v1_dns_audit_logs_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_crud_routes(
        $root,
        "DnsAuditLogs",
        "/dns_audit_logs",
        "/dns_audit_log/#dns_audit_log_id",
    );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_ip4logs_routes

setup_api_v1_ip4logs_routes

=cut

sub setup_api_v1_ip4logs_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_crud_routes(
        $root,
        "Ip4logs",
        "/ip4logs",
        "/ip4log/#ip4log_id",
    );

    $collection_route->register_sub_action({ method => 'GET', path => "/history/#search", action => 'history'});
    $collection_route->register_sub_action({ method => 'GET', path => "/archive/#search", action => 'archive'});
    $collection_route->register_sub_action({ method => 'GET', path => "/open/#search", action => 'open'});
    $collection_route->register_sub_action({ method => 'GET', path => "/mac2ip/#mac", action => 'mac2ip'});
    $collection_route->register_sub_action({ method => 'GET', path => "/ip2mac/#ip", action => 'ip2mac'});

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_ip6logs_routes

setup_api_v1_ip6logs_routes

=cut

sub setup_api_v1_ip6logs_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_crud_routes(
        $root,
        "Ip6logs",
        "/ip6logs",
        "/ip6log/#ip6log_id",
    );

    $collection_route->register_sub_action({ method => 'GET', path => "/history/#search", action => 'history'});
    $collection_route->register_sub_action({ method => 'GET', path => "/archive/#search", action => 'archive'});
    $collection_route->register_sub_action({ method => 'GET', path => "/open/#search", action => 'open'});
    $collection_route->register_sub_action({ method => 'GET', path => "/mac2ip/#mac", action => 'mac2ip'});
    $collection_route->register_sub_action({ method => 'GET', path => "/ip2mac/#ip", action => 'ip2mac'});

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_users_routes

setup_api_v1_users_routes

=cut

sub setup_api_v1_users_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_crud_routes(
        $root,
        "Users",
        "/users",
        "/user/#user_id",
    );

    $resource_route->register_sub_action({ method => 'GET', action => 'security_events' });
    $resource_route->register_sub_actions({ method => 'POST', actions => [qw(unassign_nodes close_security_events)], auditable => 1 });
    $collection_route->register_sub_actions(
        {
            method  => 'POST',
            actions => [
                qw(
                  bulk_register bulk_deregister bulk_close_security_events
                  bulk_reevaluate_access bulk_apply_security_event
                  bulk_apply_role bulk_apply_bypass_role bulk_fingerbank_refresh
                  bulk_delete bulk_import
                  )
            ],
            auditable => 1,
        }
    );
    my ($sub_collection_route, $sub_resource_route) = 
      $self->setup_api_v1_std_crud_routes(
        $resource_route,
        "Users::Nodes",
        "/nodes",
        "/node/#node_id",
    );

    my $password_route = $resource_route->any("/password")->to(controller => "Users::Password")->name("api.v1.Users.resource.Password");
    $password_route->register_sub_action({path => '', action => 'get', method => 'GET'});
    $password_route->register_sub_action({path => '', action => 'remove', method => 'DELETE', auditable => 1});
    $password_route->register_sub_action({path => '', action => 'update', method => 'PATCH', auditable => 1});
    $password_route->register_sub_action({path => '', action => 'replace', method => 'PUT', auditable => 1});
    $password_route->register_sub_action({path => '', action => 'create', method => 'POST', auditable => 1});

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_nodes_routes

setup_api_v1_nodes_routes

=cut

sub setup_api_v1_nodes_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_crud_routes(
        $root,
        "Nodes",
        "/nodes",
        "/node/#node_id",
    );

    $resource_route->register_sub_actions({
        method => 'PUT',
        actions => [ qw( register deregister restart_switchport apply_security_event close_security_event fingerbank_refresh park unpark reevaluate_access) ],
        auditable => 1,
    });

###TODO remove at v11
    $resource_route->register_sub_actions({
        method => 'POST',
        actions => [ qw( register deregister restart_switchport apply_security_event close_security_event fingerbank_refresh park unpark reevaluate_access) ],
        auditable => 1,
    });
    $collection_route->register_sub_actions({
        method => 'POST',
        actions => [
        qw(
          bulk_register bulk_deregister bulk_close_security_events
          bulk_reevaluate_access bulk_restart_switchport bulk_apply_security_event
          bulk_apply_role bulk_apply_bypass_role bulk_fingerbank_refresh
          bulk_apply_bypass_vlan bulk_import
          )
        ],
        auditable => 1
    });
###

    $resource_route->register_sub_actions({
        method => 'GET',
        actions => [ qw(fingerbank_info rapid7 security_events) ],
    });

    $collection_route->register_sub_actions({
        method => 'PUT',
        actions => [
        qw(
          bulk_register bulk_deregister bulk_close_security_events
          bulk_reevaluate_access bulk_restart_switchport bulk_apply_security_event
          bulk_apply_role bulk_apply_bypass_role bulk_fingerbank_refresh
          bulk_apply_bypass_vlan bulk_import
          )
        ],
        auditable => 1
    });

    $collection_route->register_sub_action({
        method => 'POST',
        action => 'network_graph',
    });

    return ( $collection_route, $resource_route );
}


=head2 add_subroutes

add_subroutes

=cut

sub add_subroutes {
    my ($self, $root, $controller, $method, @subroutes) = @_;
    my $name = $root->name;
    for my $subroute (@subroutes) {
        $root
          ->any([$method] => "/$subroute")
          ->to("$controller#$subroute")
          ->name("${name}.$subroute");
    }
    return ;
}

=head2 setup_api_v1_security_events_routes

setup_api_v1_security_events_routes

=cut

sub setup_api_v1_security_events_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_crud_routes(
        $root,
        "SecurityEvents",
        "/security_events",
        "/security_event/#security_event_id",
    );

    $collection_route->any(['GET'] => '/by_mac/#search')->to("SecurityEvents#by_mac")->name("api.v1.SecurityEvents.by_mac");
    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_node_categories_routes

setup_api_v1_node_categories_routes

=cut

sub setup_api_v1_node_categories_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_crud_readonly_routes(
        $root,
        "NodeCategories",
        "/node_categories",
        "/node_category/#node_category_id",
        "api.v1.NodeCategories",
    );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_admin_api_audit_logs_routes

setup_api_v1_admin_api_audit_logs_routes

=cut

sub setup_api_v1_admin_api_audit_logs_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_crud_readonly_routes(
        $root,
        "AdminApiAuditLogs",
        "/admin_api_audit_logs",
        "/admin_api_audit_log/#admin_api_audit_log_id",
        "api.v1.AdminApiAuditLogs",
    );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_classes_routes

setup_api_v1_classes_routes

=cut

sub setup_api_v1_classes_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_crud_readonly_routes(
        $root,
        "Classes",
        "/classes",
        "/class/#class_id",
        "api.v1.Classes",
    );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_wrix_locations_routes

setup_api_v1_wrix_locations_routes

=cut

sub setup_api_v1_wrix_locations_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_crud_routes(
        $root,
        "WrixLocations",
        "/wrix_locations",
        "/wrix_location/#wrix_location_id",
    );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_std_crud_readonly_routes

setup_api_v1_std_crud_readonly_routes

=cut

sub setup_api_v1_std_crud_readonly_routes {
    my ($self, $root, $controller, $collection_path, $resource_path, $name) = @_;
    my $collection_route = $root->any($collection_path)->name($name);
    $collection_route->any(['GET'])->to("$controller#list")->name("${name}.list");
    $collection_route->any(['POST'] => "/search")->to("$controller#search")->name("${name}.search");
    my $resource_route = $root->under($resource_path)->to("${controller}#resource")->name("${name}.resource");
    $resource_route->any(['GET'])->to("$controller#get")->name("${name}.resource.get");
    return ($collection_route, $resource_route);
}

sub make_name_from_controller {
    my ($self, $root, $controller) = @_;
    my $name = $controller;
    my $root_name = $root->name;
    $name =~ s/::/./g;
    $name = "${root_name}.${name}";
    return $name;
}

=head2 setup_api_v1_std_crud_routes

setup_api_v1_std_crud_routes

=cut

sub setup_api_v1_std_crud_routes {
    my ($self, $root, $controller, $collection_path, $resource_path, $name) = @_;
    my $root_name = $root->name;
    if (!defined $name) {
        $name = $self->make_name_from_controller($root, $controller);
    }

    my $collection_route = $root->any($collection_path)->to(controller=> $controller)->name($name);
    $self->setup_api_v1_std_crud_collection_routes($collection_route);
    my $resource_route = $root->under($resource_path)->to(controller => $controller, action => "resource")->name("${name}.resource");
    $self->setup_api_v1_std_crud_resource_routes($resource_route);
    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_std_crud_collection_routes

setup_api_v1_std_crud_collection_routes

=cut

sub setup_api_v1_std_crud_collection_routes {
    my ($self, $root) = @_;
    $root->register_sub_action({path => '', action => 'list', method => 'GET'});
    $root->register_sub_action({path => '', action => 'create', method => 'POST', auditable => 1});
    $root->register_sub_action({action => 'search', method => 'POST'});
    return ;
}

=head2 setup_api_v1_std_crud_resource_routes

setup_api_v1_std_crud_resource_routes

=cut

sub setup_api_v1_std_crud_resource_routes {
    my ($self, $root) = @_;
    $root->register_sub_action({path => '', action => 'get', method => 'GET'});
    $root->register_sub_action({path => '', action => 'update', method => 'PATCH', auditable => 1});
    $root->register_sub_action({path => '', action => 'replace', method => 'PUT', auditable => 1});
    $root->register_sub_action({path => '', action => 'remove', method => 'DELETE', auditable => 1});
    return ;
}

=head2 setup_api_v1_std_config_routes

setup_api_v1_std_config_routes

=cut

sub setup_api_v1_std_config_routes {
    my ($self, $root, $controller, $collection_path, $resource_path, $name) = @_;
    if (!defined $name) {
        $name = $self->make_name_from_controller($root, $controller);
    }

    my $collection_route = $root->any($collection_path)->to(controller => $controller)->name($name);
    $self->setup_api_v1_std_config_collection_routes($collection_route, $name, $controller);
    my $resource_route = $root->under($resource_path)->to(controller => $controller, action => "resource")->name("${name}.resource");
    $self->setup_api_v1_std_config_resource_routes($resource_route);
    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_std_config_collection_routes

setup_api_v1_standard_config_collection_routes

=cut

sub setup_api_v1_std_config_collection_routes {
    my ($self, $root, $name, $controller) = @_;
    $root->register_sub_action({path => '', action => 'list', method => 'GET'});
    $root->register_sub_action({path => '', action => 'create', method => 'POST', auditable => 1});
    $root->register_sub_action({path => '', action => 'options', method => 'OPTIONS'});
    $root->register_sub_actions({actions => [qw(sort_items bulk_update)], method => 'PATCH', auditable => 1});
    $root->register_sub_action({action => 'search', method => 'POST'});
    $root->register_sub_action({action => 'bulk_delete', method => 'POST', auditable => 1});
    $root->register_sub_action({action => 'bulk_import', method => 'POST', auditable => 1});
    return ;
}

=head2 setup_api_v1_std_config_resource_routes

setup_api_v1_std_config_resource_routes

=cut

sub setup_api_v1_std_config_resource_routes {
    my ($self, $root) = @_;
    $root->register_sub_action({path => '', action => 'get', method => 'GET'});
    $root->register_sub_action({path => '', action => 'update', method => 'PATCH', auditable => 1});
    $root->register_sub_action({path => '', action => 'replace', method => 'PUT', auditable => 1});
    $root->register_sub_action({path => '', action => 'remove', method => 'DELETE', auditable => 1});
    $root->register_sub_action({path => '', action => 'resource_options', method => 'OPTIONS'});
    return ;
}

=head2 setup_api_v1_config_admin_roles_routes

 setup_api_v1_config_admin_roles_routes

=cut

sub setup_api_v1_config_admin_roles_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::AdminRoles",
        "/admin_roles",
        "/admin_role/#admin_role_id",
        "api.v1.Config.AdminRoles"
    );

    return ($collection_route, $resource_route);
}


=head2 setup_api_v1_config_bases_routes

 setup_api_v1_config_bases_routes

=cut

sub setup_api_v1_config_bases_routes {
    my ($self, $root, $db_routes) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::Bases",
        "/bases",
        "/base/#base_id",
        "api.v1.Config.Bases"
    );

    $collection_route->register_sub_action({ action => 'test_smtp', method => 'POST'});

    return unless $db_routes;
    my $database_route = $root->any("/base/database")->name("api.v1.Config.Bases");
    $database_route
      ->any(["POST"] => "/test")
      ->to("Config::Bases#database_test")
      ->name("api.v1.Config.Bases.database_test");
    $database_route
      ->any(["POST"] => "/secure_installation")
      ->to("Config::Bases#database_secure_installation")
      ->name("api.v1.Config.Bases.database_secure_installation");
    $database_route
      ->any(["POST"] => "/create")
      ->to("Config::Bases#database_create")
      ->name("api.v1.Config.Bases.database_create");
    $database_route
      ->any(["POST"] => "/assign")
      ->to("Config::Bases#database_assign")
      ->name("api.v1.Config.Bases.database_assign");

    return ($collection_route, $resource_route);
}


=head2 setup_api_v1_config_billing_tiers_routes

 setup_api_v1_config_billing_tiers_routes

=cut

sub setup_api_v1_config_billing_tiers_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::BillingTiers",
        "/billing_tiers",
        "/billing_tier/#billing_tier_id",
        "api.v1.Config.BillingTiers"
    );

    return ($collection_route, $resource_route);
}


=head2 setup_api_v1_config_self_services_routes

 setup_api_v1_config_self_services_routes

=cut

sub setup_api_v1_config_self_services_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::SelfServices",
        "/self_services",
        "/self_service/#self_service_id",
        "api.v1.Config.SelfServices"
    );

    return ($collection_route, $resource_route);
}


=head2 setup_api_v1_config_domains_routes

 setup_api_v1_config_domains_routes

=cut

sub setup_api_v1_config_domains_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::Domains",
        "/domains",
        "/domain/#domain_id",
        "api.v1.Config.Domains"
    );
    $resource_route->register_sub_action({path => '/test_join', action => 'test_join', method => 'GET'});
    $resource_route->register_sub_actions({method=> 'POST', actions => [qw(join unjoin rejoin)], auditable => 1});
    return ($collection_route, $resource_route);
}


=head2 setup_api_v1_config_floating_devices_routes

 setup_api_v1_config_floating_devices_routes

=cut

sub setup_api_v1_config_floating_devices_routes {
    my ( $self, $root ) = @_;
    my ( $collection_route, $resource_route ) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::FloatingDevices",
        "/floating_devices",
        "/floating_device/#floating_device_id",
        "api.v1.Config.FloatingDevices"
      );

    return ($collection_route, $resource_route);
}


=head2 setup_api_v1_config_maintenance_tasks_routes

 setup_api_v1_config_maintenance_tasks_routes

=cut

sub setup_api_v1_config_maintenance_tasks_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::MaintenanceTasks",
        "/maintenance_tasks",
        "/maintenance_task/#maintenance_task_id",
        "api.v1.Config.MaintenanceTasks"
      );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_config_network_behavior_policies_routes

 setup_api_v1_config_network_behavior_policies_routes

=cut

sub setup_api_v1_config_network_behavior_policies_routes{
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::NetworkBehaviorPolicies",
        "/network_behavior_policies",
        "/network_behavior_policy/#network_behavior_policy_id",
        "api.v1.Config.NetworkBehaviorPolicies"
    );

    return ($collection_route, $resource_route);
}


=head2 setup_api_v1_config_pki_providers_routes

 setup_api_v1_config_pki_providers_routes

=cut

sub setup_api_v1_config_pki_providers_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::PkiProviders",
        "/pki_providers",
        "/pki_provider/#pki_provider_id",
        "api.v1.Config.PkiProviders"
    );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_config_portal_modules_routes

 setup_api_v1_config_portal_modules_routes

=cut

sub setup_api_v1_config_portal_modules_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::PortalModules",
        "/portal_modules",
        "/portal_module/#portal_module_id",
        "api.v1.Config.PortalModules"
    );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_config_provisionings_routes

 setup_api_v1_config_provisionings_routes

=cut

sub setup_api_v1_config_provisionings_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::Provisionings",
        "/provisionings",
        "/provisioning/#provisioning_id",
        "api.v1.Config.Provisionings"
    );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_config_radiusd_routes

 setup_api_v1_config_radiusd_routes

=cut

sub setup_api_v1_config_radiusd_routes {
    my ($self, $root) = @_;
    my $radiusd_route = $root->any("/radiusd")->name("api.v1.Config.Radiusd");
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $radiusd_route,
        "Config::Radiusd::FastProfiles",
        "/fast_profiles",
        "/fast_profile/#fast_profile_id",
        "api.v1.Config.Radiusd.FastProfiles"
    );

    ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $radiusd_route,
        "Config::Radiusd::TLSProfiles",
        "/tls_profiles",
        "/tls_profile/#tls_profile_id",
        "api.v1.Config.Radiusd.TLSProfiles"
    );

      $self->setup_api_v1_std_config_routes(
        $radiusd_route,
        "Config::Radiusd::OCSPProfiles",
        "/ocsp_profiles",
        "/ocsp_profile/#ocsp_profile_id",
        "api.v1.Config.Radiusd.OCSPProfiles"
    );

      $self->setup_api_v1_std_config_routes(
        $radiusd_route,
        "Config::Radiusd::EAPProfiles",
        "/eap_profiles",
        "/eap_profile/#eap_profile_id",
        "api.v1.Config.Radiusd.EAPProfiles"
    );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_config_realms_routes

 setup_api_v1_config_realms_routes

=cut

sub setup_api_v1_config_realms_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::Realms",
        "/realms",
        "/realm/#realm_id",
        "api.v1.Config.Realms"
    );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_config_roles_routes

 setup_api_v1_config_roles_routes

=cut

sub setup_api_v1_config_roles_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::Roles",
        "/roles",
        "/role/#role_id",
        "api.v1.Config.Roles"
    );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_config_scans_routes

 setup_api_v1_config_scans_routes

=cut

sub setup_api_v1_config_scans_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::Scans",
        "/scans",
        "/scan/#scan_id",
        "api.v1.Config.Scans"
    );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_config_switch_groups_routes

 setup_api_v1_config_switch_groups_routes

=cut

sub setup_api_v1_config_switch_groups_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::SwitchGroups",
        "/switch_groups",
        "/switch_group/#switch_group_id",
        "api.v1.Config.SwitchGroups"
    );

    $resource_route->register_sub_action({action => 'members', method => 'GET'});
    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_config_syslog_forwarders_routes

 setup_api_v1_config_syslog_forwarders_routes

=cut

sub setup_api_v1_config_syslog_forwarders_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::SyslogForwarders",
        "/syslog_forwarders",
        "/syslog_forwarder/#syslog_forwarder_id",
        "api.v1.Config.SyslogForwarders"
    );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_config_traffic_shaping_policies_routes

 setup_api_v1_config_traffic_shaping_policies_routes

=cut

sub setup_api_v1_config_traffic_shaping_policies_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::TrafficShapingPolicies",
        "/traffic_shaping_policies",
        "/traffic_shaping_policy/#traffic_shaping_policy_id",
        "api.v1.Config.TrafficShapingPolicies"
    );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_config_security_events_routes

 setup_api_v1_config_security_events_routes

=cut

sub setup_api_v1_config_security_events_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::SecurityEvents",
        "/security_events",
        "/security_event/#security_event_id",
        "api.v1.Config.SecurityEvents"
    );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_config_l2_networks_routes

setup_api_v1_config_l2_networks_routes

=cut

sub setup_api_v1_config_l2_networks_routes {
    my ($self, $root) = @_;
    my $collection_route = $root->any("/l2_networks")->name("api.v1.Config.L2Networks");
    $collection_route->any(['GET'] => "/")->to("Config::L2Networks#list")->name("api.v1.Config.L2Networks.list");
    $collection_route->any(['OPTIONS'] => "/")->to("Config::L2Networks#options")->name("api.v1.Config.L2Networks.options");
    my $resource_route = $root->under("/l2_network/#network_id")->to("Config::L2Networks#resource")->name("api.v1.Config.L2Networks.resource");
    $resource_route->any(['GET'] => "/")->to("Config::L2Networks#get")->name("api.v1.Config.L2Networks.get");
    $resource_route->any(['PATCH'] => "/")->to("Config::L2Networks#update")->name("api.v1.Config.L2Networks.update");
    $resource_route->any(['PUT'] => "/")->to("Config::L2Networks#replace")->name("api.v1.Config.L2Networks.replace");
    $resource_route->any(['OPTIONS'] => "/")->to("Config::L2Networks#resource_options")->name("api.v1.Config.L2Networks.resource_options");
    return (undef, $resource_route);
}

=head2 setup_api_v1_config_routed_networks_routes

setup_api_v1_config_routed_networks_routes

=cut

sub setup_api_v1_config_routed_networks_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::RoutedNetworks",
        "/routed_networks",
        "/routed_network/#network_id",
        "api.v1.Config.RoutedNetworks"
    );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_config_firewalls_routes

setup_api_v1_config_firewalls_routes

=cut

sub setup_api_v1_config_firewalls_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::Firewalls",
        "/firewalls",
        "/firewall/#firewall_id",
        "api.v1.Config.Firewalls"
    );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_config_connection_profiles_routes

setup_api_v1_config_connection_profiles_routes

=cut

sub setup_api_v1_config_connection_profiles_routes {
    my ($self, $root) = @_;
    my $controller = "Config::ConnectionProfiles";
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        $controller,
        "/connection_profiles",
        "/connection_profile/#connection_profile_id",
        "api.v1.Config.ConnectionProfiles"
    );

    $self->setup_api_v1_config_connection_profiles_files_routes($controller, $resource_route);
    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_config_connection_profiles_files_routes

setup_api_v1_config_connection_profiles_files_routes

=cut

sub setup_api_v1_config_connection_profiles_files_routes {
    my ($self, $controller, $root) = @_;
    my $name = "api.v1.Config.ConnectionProfiles.resource.files";
    my $files_route = $root->any("/files")->name($name);
    $files_route->any(['GET'])->to("$controller#files" => {})->name("${name}.dir");
    my $file_route = $files_route->any("/*file_name")->name("${name}.file");
    $file_route->any(['GET'])->to("$controller#get_file" => {})->name("${name}.file.get");
    $file_route->any(['PATCH'])->to("$controller#replace_file" => {})->name("${name}.file.replace");
    $file_route->any(['PUT'])->to("$controller#new_file" => {})->name("${name}.file.new");
    $file_route->any(['DELETE'])->to("$controller#delete_file" => {})->name("${name}.file.delete");
    my $preview_route = $root->get("/preview/*file_name")->to("$controller#preview_file")->name("api.v1.Config.ConnectionProfiles.resource.preview");

    return ;
}

=head2 setup_api_v1_config_switches_routes

setup_api_v1_config_switches_routes

=cut

sub setup_api_v1_config_switches_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::Switches",
        "/switches",
        "/switch/#switch_id",
        "api.v1.Config.Switches"
    );

    $resource_route->any(['POST'] => "/invalidate_cache")->to("Config::Switches#invalidate_cache", auditable => 1)->name("api.v1.Config.Switches.invalidate_cache");

    return ($collection_route, $resource_route);
}


=head2 setup_api_v1_config_template_switches_routes

setup_api_v1_config_template_switches_routes

=cut

sub setup_api_v1_config_template_switches_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::TemplateSwitches",
        "/template_switches",
        "/template_switch/#template_switch_id",
        "api.v1.Config.TemplateSwitches"
    );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_config_sources_routes

setup_api_v1_config_sources_routes

=cut

sub setup_api_v1_config_sources_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::Sources",
        "/sources",
        "/source/#source_id",
        "api.v1.Config.Source"
    );

    $collection_route->any(['POST'] => "/test")->to("Config::Sources#test")->name("api.v1.Config.Sources.test");
    $resource_route->register_sub_action({ method => 'GET', action => 'saml_metadata'});

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_config_syslog_parsers_routes

setup_api_v1_config_syslog_parsers_routes

=cut

sub setup_api_v1_config_syslog_parsers_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::SyslogParsers",
        "/syslog_parsers",
        "/syslog_parser/#syslog_parser_id",
        "api.v1.Config.SyslogParsers"
    );

    $collection_route->any(['POST'] => "/dry_run")->to("Config::SyslogParsers#dry_run")->name("api.v1.Config.SyslogParsers.dry_run");

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_config_filters_routes

setup_api_v1_config_filters_routes

=cut

sub setup_api_v1_config_filters_routes {
    my ($self, $root) = @_;
    my $collection_route = $root->any(['GET'] => '/filters')->to(controller => "Config::Filters", action => 'list')->name("api.v1.Config.Filters.list");
    my $resource_route = $root->under("/filter/#filter_id")->to(controller => "Config::Filters", action => "resource")->name("api.v1.Config.Filters.resource");
    $resource_route->any(['GET'])->to(controller => "Config::Filters", action => "get")->name("api.v1.Config.Filters.resource.get");
    $resource_route->any(['PUT'])->to(controller => "Config::Filters", action => "replace")->name("api.v1.Config.Filters.resource.replace");

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_config_fingerbank_settings_routes

setup_api_v1_config_fingerbank_settings_routes

=cut

sub setup_api_v1_config_fingerbank_settings_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::FingerbankSettings",
        "/fingerbank_settings",
        "/fingerbank_setting/#fingerbank_setting_id",
        "api.v1.Config.FingerbankSettings"
    );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_config_certificates_routes

setup_api_v1_config_certificates_routes

=cut

sub setup_api_v1_config_certificates_routes {
    my ($self, $root) = @_;
    my $root_name = $root->name;
    $root->any(["GET"] => "/certificates/lets_encrypt/test")->to("Config::Certificates#lets_encrypt_test")->name("${root_name}.Certificates.lets_encrypt_test");

    my $resource_route = $root->under("/certificate/#certificate_id")->to(controller => "Config::Certificates", action => 'resource')->name("${root_name}.Certificates.resource");
    my $resource_name = $resource_route->name;
    $resource_route->any(['GET'] => '')->to(action => "get")->name("${resource_name}.get");
    $resource_route->any(['PUT'])->to(action => "replace")->name("${resource_name}.replace");
    $resource_route->any(['GET'] => "/info")->to(action => "info")->name("${resource_name}.info");
    $resource_route->any(['POST'] => "/generate_csr")->to(action => "generate_csr")->name("${resource_name}.generate_csr");
    $resource_route->any(['PUT'] => "/lets_encrypt")->to(action => "lets_encrypt_replace")->name("${resource_name}.lets_encrypt_replace");

    return (undef, $resource_route);
}

=head2 setup_api_v1_translations_routes

setup_api_v1_translations_routes

=cut

sub setup_api_v1_translations_routes {
    my ($self, $root) = @_;
    my $collection_route =
      $root->any( ['GET'] => "/translations" )
      ->to(controller => "Translations", action => "list")
      ->name("api.v1.Config.Translations.list");
    my $resource_route =
      $root->under("/translation/#translation_id")
      ->to(controller => "Translations", action => "resource")
      ->name("api.v1.Config.Translations.resource");
    $resource_route->any(['GET'])->to(action => "get")->name("api.v1.Config.Translations.resource.get");
    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_preferences_routes

setup_api_v1_preferences_routes

=cut

sub setup_api_v1_preferences_routes {
    my ($self, $root) = @_;
    my $collection_route = $root->any(['GET'] => "/preferences")->to("Preferences#list")->name("api.v1.Config.Preferences.list");
    my $resource_route = $root->under("/preference/#preference_id")->to("Preferences#resource")->name("api.v1.Config.Preferences.resource");
    $resource_route->any(['GET'])->to("Preferences#get")->name("api.v1.Config.Preferences.resource.get");
    $resource_route->any(['PUT'])->to("Preferences#replace")->name("api.v1.Config.Preferences.resource.replace");
    $resource_route->any(['DELETE'])->to("Preferences#delete")->name("api.v1.Config.Preferences.resource.delete");
    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_reports_routes

setup_api_v1_reports_routes

=cut

sub setup_api_v1_reports_routes {
    my ($self, $root) = @_;
    $root
      ->any(['GET'] => "/os")
      ->to("Reports#os_all")
      ->name("api.v1.Reports.os_all");
    $root
      ->any(['GET'] => "/os/#start/#end")
      ->to("Reports#os_range")
      ->name("api.v1.Reports.os_range");
    $root
      ->any(['GET'] => "/os/active")
      ->to("Reports#os_active")
      ->name("api.v1.Reports.os_active");
    $root
      ->any(['GET'] => "/osclass")
      ->to("Reports#osclass_all")
      ->name("api.v1.Reports.osclass_all");
    $root
      ->any(['GET'] => "/osclass/active")
      ->to("Reports#osclass_active")
      ->name("api.v1.Reports.osclass_active");
    $root
      ->any(['GET'] => "/inactive")
      ->to("Reports#inactive_all")
      ->name("api.v1.Reports.inactive_all");
    $root
      ->any(['GET'] => "/active")
      ->to("Reports#active_all")
      ->name("api.v1.Reports.active_all");
    $root
      ->any(['GET'] => "/unregistered")
      ->to("Reports#unregistered_all")
      ->name("api.v1.Reports.unregistered_all");
    $root
      ->any(['GET'] => "/unregistered/active")
      ->to("Reports#unregistered_active")
      ->name("api.v1.Reports.unregistered_active");
    $root
      ->any(['GET'] => "/registered")
      ->to("Reports#registered_all")
      ->name("api.v1.Reports.registered_all");
    $root
      ->any(['GET'] => "/registered/active")
      ->to("Reports#registered_active")
      ->name("api.v1.Reports.registered_active");
    $root
      ->any(['GET'] => "/unknownprints")
      ->to("Reports#unknownprints_all")
      ->name("api.v1.Reports.unknownprints_all");
    $root
      ->any(['GET'] => "/unknownprints/active")
      ->to("Reports#unknownprints_active")
      ->name("api.v1.Reports.unknownprints_active");
    $root
      ->any(['GET'] => "/statics")
      ->to("Reports#statics_all")
      ->name("api.v1.Reports.statics_all");
    $root
      ->any(['GET'] => "/statics/active")
      ->to("Reports#statics_active")
      ->name("api.v1.Reports.statics_active");
    $root
      ->any(['GET'] => "/opensecurity_events")
      ->to("Reports#opensecurity_events_all")
      ->name("api.v1.Reports.opensecurity_events_all");
    $root
      ->any(['GET'] => "/opensecurity_events/active")
      ->to("Reports#opensecurity_events_active")
      ->name("api.v1.Reports.opensecurity_events_active");
    $root
      ->any(['GET'] => "/connectiontype")
      ->to("Reports#connectiontype_all")
      ->name("api.v1.Reports.connectiontype_all");
    $root
      ->any(['GET'] => "/connectiontype/#start/#end")
      ->to("Reports#connectiontype_range")
      ->name("api.v1.Reports.connectiontype_range");
    $root
      ->any(['GET'] => "/connectiontype/active")
      ->to("Reports#connectiontype_active")
      ->name("api.v1.Reports.connectiontype_active");
    $root
      ->any(['GET'] => "/connectiontypereg")
      ->to("Reports#connectiontypereg_all")
      ->name("api.v1.Reports.connectiontypereg_all");
    $root
      ->any(['GET'] => "/connectiontypereg/active")
      ->to("Reports#connectiontypereg_active")
      ->name("api.v1.Reports.connectiontypereg_active");
    $root
      ->any(['GET'] => "/ssid")
      ->to("Reports#ssid_all")
      ->name("api.v1.Reports.ssid_all");
    $root
      ->any(['GET'] => "/ssid/#start/#end")
      ->to("Reports#ssid_range")
      ->name("api.v1.Reports.ssid_range");
    $root
      ->any(['GET'] => "/ssid/active")
      ->to("Reports#ssid_active")
      ->name("api.v1.Reports.ssid_active");
    $root
      ->any(['GET'] => "/osclassbandwidth/#start/#end")
      ->to("Reports#osclassbandwidth_range")
      ->name("api.v1.Reports.osclassbandwidth_range");
    $root
      ->any(['GET'] => "/osclassbandwidth/hour")
      ->to("Reports#osclassbandwidth_hour")
      ->name("api.v1.Reports.osclassbandwidth_hour");
    $root
      ->any(['GET'] => "/osclassbandwidth/day")
      ->to("Reports#osclassbandwidth_day")
      ->name("api.v1.Reports.osclassbandwidth_day");
    $root
      ->any(['GET'] => "/osclassbandwidth/week")
      ->to("Reports#osclassbandwidth_week")
      ->name("api.v1.Reports.osclassbandwidth_week");
    $root
      ->any(['GET'] => "/osclassbandwidth/month")
      ->to("Reports#osclassbandwidth_month")
      ->name("api.v1.Reports.osclassbandwidth_month");
    $root
      ->any(['GET'] => "/osclassbandwidth/year")
      ->to("Reports#osclassbandwidth_year")
      ->name("api.v1.Reports.osclassbandwidth_year");
    $root
      ->any(['GET'] => "/nodebandwidth/#start/#end")
      ->to("Reports#nodebandwidth_range")
      ->name("api.v1.Reports.nodebandwidth_range");
    $root
      ->any(['GET'] => "/nodebandwidth/hour")
      ->to("Reports#nodebandwidth_hour")
      ->name("api.v1.Reports.nodebandwidth_hour");
    $root
      ->any(['GET'] => "/nodebandwidth/day")
      ->to("Reports#nodebandwidth_day")
      ->name("api.v1.Reports.nodebandwidth_day");
    $root
      ->any(['GET'] => "/nodebandwidth/week")
      ->to("Reports#nodebandwidth_week")
      ->name("api.v1.Reports.nodebandwidth_week");
    $root
      ->any(['GET'] => "/nodebandwidth/month")
      ->to("Reports#nodebandwidth_month")
      ->name("api.v1.Reports.nodebandwidth_month");
    $root
      ->any(['GET'] => "/nodebandwidth/year")
      ->to("Reports#nodebandwidth_year")
      ->name("api.v1.Reports.nodebandwidth_year");
    $root
      ->any(['GET'] => "/userbandwidth/#start/#end")
      ->to("Reports#userbandwidth_range")
      ->name("api.v1.Reports.userbandwidth_range");
    $root
      ->any(['GET'] => "/userbandwidth/hour")
      ->to("Reports#userbandwidth_hour")
      ->name("api.v1.Reports.userbandwidth_hour");
    $root
      ->any(['GET'] => "/userbandwidth/day")
      ->to("Reports#userbandwidth_day")
      ->name("api.v1.Reports.userbandwidth_day");
    $root
      ->any(['GET'] => "/userbandwidth/week")
      ->to("Reports#userbandwidth_week")
      ->name("api.v1.Reports.userbandwidth_week");
    $root
      ->any(['GET'] => "/userbandwidth/month")
      ->to("Reports#userbandwidth_month")
      ->name("api.v1.Reports.userbandwidth_month");
    $root
      ->any(['GET'] => "/userbandwidth/year")
      ->to("Reports#userbandwidth_year")
      ->name("api.v1.Reports.userbandwidth_year");
    $root
      ->any(['GET'] => "/topauthenticationfailures/mac/#start/#end")
      ->to("Reports#topauthenticationfailures_by_mac")
      ->name("api.v1.Reports.topauthenticationfailures_by_mac");
    $root
      ->any(['GET'] => "/topauthenticationfailures/ssid/#start/#end")
      ->to("Reports#topauthenticationfailures_by_ssid")
      ->name("api.v1.Reports.topauthenticationfailures_by_ssid");
    $root
      ->any(['GET'] => "/topauthenticationfailures/username/#start/#end")
      ->to("Reports#topauthenticationfailures_by_username")
      ->name("api.v1.Reports.topauthenticationfailures_by_username");
    $root
      ->any(['GET'] => "/topauthenticationsuccesses/mac/#start/#end")
      ->to("Reports#topauthenticationsuccesses_by_mac")
      ->name("api.v1.Reports.topauthenticationsuccesses_by_mac");
    $root
      ->any(['GET'] => "/topauthenticationsuccesses/ssid/#start/#end")
      ->to("Reports#topauthenticationsuccesses_by_ssid")
      ->name("api.v1.Reports.topauthenticationsuccesses_by_ssid");
    $root
      ->any(['GET'] => "/topauthenticationsuccesses/username/#start/#end")
      ->to("Reports#topauthenticationsuccesses_by_username")
      ->name("api.v1.Reports.topauthenticationsuccesses_by_username");
    $root
      ->any(['GET'] => "/topauthenticationsuccesses/computername/#start/#end")
      ->to("Reports#topauthenticationsuccesses_by_computername")
      ->name("api.v1.Reports.topauthenticationsuccesses_by_computername");
    return ( undef, undef );
}

=head2 setup_api_v1_config_interfaces_routes

setup_api_v1_config_interfaces_routes

=cut

sub setup_api_v1_config_interfaces_routes {
    my ($self, $root) = @_;
    my $root_name = $root->name;
    my $name = "$root_name.Interfaces";
    my $controller = "Config::Interfaces";
    my $collection_route = $root->any("/interfaces")->to(controller => $controller)->name($name);
    $collection_route->register_sub_action({path => '', action => 'list', method => 'GET'});
    $collection_route->register_sub_action({path => '', action => 'create', method => 'POST', auditable => 1});
    my $resource_route = $root->under("/interface/#interface_id")->to(controller => "Config::Interfaces", action => "resource")->name("$name.resource");
    $resource_route->register_sub_action({path => '', action => 'get', method => 'GET'});
    $resource_route->register_sub_action({path => '', action => 'update', method => 'PATCH', auditable => 1});
    $resource_route->register_sub_action({path => '', action => 'delete', method => 'DELETE', auditable => 1});
    $resource_route->register_sub_actions({method=> 'POST', actions => [qw(up down)], auditable => 1});
    return ($collection_route, $resource_route);
}

sub setup_api_v1_dynamic_reports_routes {
    my ( $self, $root ) = @_;
    my $root_name = $root->name;
    my $controller = "DynamicReports";
    my $name = "$root_name.DynamicReports";
    my $collection_route = $root->any("/dynamic_reports")->to(controller => $controller)->name($name);
    $collection_route->register_sub_action({path => '', action => 'list', method => 'GET'});
    my $resource_route = $root->under("/dynamic_report/#report_id")->to(controller => $controller, action => "resource")->name("${name}.resource");
    $resource_route->register_sub_action({path => '', action => 'get', method => 'GET'});
    $resource_route->register_sub_action({action => 'search', method => 'POST'});
    return ( $collection_route, $resource_route );
}

=head2 setup_api_v1_cluster_routes

setup_api_v1_cluster_routes

=cut

sub setup_api_v1_cluster_routes {
    my ($self, $root) = @_;
    my $resource_route = $root->any("/cluster")->to(controller => "Cluster")->name("api.v1.Cluster");;
    $resource_route->any(['GET'] => "/servers")->to(action => "servers")->name("api.v1.Cluster.servers");
    $resource_route->any(['GET'] => "/config")->to(action => "config")->name("api.v1.Cluster.config");
    return (undef, $resource_route);
}

=head2 setup_api_v1_system_services_routes

setup_api_v1_system_services_routes

=cut

sub setup_api_v1_system_services_routes {
    my ($self, $root) = @_;
    my $resource_route = $root->under("/system_service/#system_service_id")->to("SystemServices#resource")->name("api.v1.Config.SystemServices.resource");
    $self->add_subroutes($resource_route, "SystemServices", "GET", qw(status));
    $self->add_subroutes($resource_route, "SystemServices", "POST", qw(start stop restart enable disable));
    
    return ($resource_route);
}

=head2 setup_api_v1_services_routes

setup_api_v1_services_routes

=cut

sub setup_api_v1_services_routes {
    my ($self, $root) = @_;
    my $collection_route = $root->any("/services")->to(controller => "Services")->name("api.v1.Config.Services");
    $collection_route->register_sub_action({action => 'list', path => '', method => 'GET'});
    $collection_route->register_sub_actions({actions => [qw(status_all)], method => 'GET'});
    my $resource_route = $root->under("/service/#service_id")->to("Services#resource")->name("api.v1.Config.Services.resource");
    $self->add_subroutes($resource_route, "Services", "GET", qw(status));
    $self->add_subroutes($resource_route, "Services", "POST", qw(start stop restart enable disable update_systemd));
    
    my $cs_collection_route = $collection_route->any("/cluster_statuses")->to(controller => "Services::ClusterStatuses")->name("api.v1.Config.Services.ClusterStatuses");
    $cs_collection_route->register_sub_action({action => 'list', path => '', method => 'GET'});
    my $cs_resource_route = $root->under("/services/cluster_status/#server_id")->to("Services::ClusterStatuses#resource")->name("api.v1.Config.Services.ClusterStatuses.resource");
    $cs_resource_route->register_sub_action({action => 'get', path => '', method => 'GET'});

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_authentication_routes

setup_api_v1_authentication_routes

=cut

sub setup_api_v1_authentication_routes {
    my ($self, $root) = @_;
    my $route = $root->any("/authentication")->name("api.v1.Authentication");
    $route->any(['POST'] => "/admin_authentication")->to("Authentication#adminAuthentication")->name("api.v1.Authentication.admin_authentication");
    return ;
}

=head2 setup_api_v1_queues_routes

setup_api_v1_queues_routes

=cut

sub setup_api_v1_queues_routes {
    my ($self, $root) = @_;
    my $route = $root->any("/queues")->name("api.v1.Queues");
    $route->register_sub_action({ action => "stats", method => "GET", controller => 'Queues'});
    return ;
}

=head2 setup_api_v1_fingerbank_routes

setup_api_v1_fingerbank_routes

=cut

sub setup_api_v1_fingerbank_routes {
    my ($self, $root) = @_;
    my $route = $root->any("/fingerbank")->to(controller => 'Fingerbank')->name("api.v1.Fingerbank");

    $route->register_sub_action({ action => "update_upstream_db", method => "POST"});
    $route->register_sub_action({ action => "account_info", method => "GET" });
    $route->register_sub_action({ action => "can_use_nba_endpoints", method => "GET" });
    my $upstream = $route->any("/upstream")->to(scope => "Upstream")->name( $route->name . ".Upstream");
    my $local_route = $route->any("/local")->to(scope => "Local")->name( $route->name . ".Local");
    my $all_route = $route->any("/all")->to(scope => "All")->name( $route->name . ".All");
    $self->setup_api_v1_std_fingerbank_routes($all_route, $upstream, $local_route, "Combinations", "/combinations", "/combination/#combination_id");
    $self->setup_api_v1_std_fingerbank_routes($all_route, $upstream, $local_route, "Devices", "/devices", "/device/#device_id");
    $self->setup_api_v1_std_fingerbank_routes($all_route, $upstream, $local_route, "DHCP6Enterprises", "/dhcp6_enterprises", "/dhcp6_enterprise/#dhcp6_enterprise_id");
    $self->setup_api_v1_std_fingerbank_routes($all_route, $upstream, $local_route, "DHCP6Fingerprints", "/dhcp6_fingerprints", "/dhcp6_fingerprint/#dhcp6_fingerprint_id");
    $self->setup_api_v1_std_fingerbank_routes($all_route, $upstream, $local_route, "DHCPFingerprints", "/dhcp_fingerprints", "/dhcp_fingerprint/#dhcp_fingerprint_id");
    $self->setup_api_v1_std_fingerbank_routes($all_route, $upstream, $local_route, "DHCPVendors", "/dhcp_vendors", "/dhcp_vendor/#dhcp_vendor_id");
    $self->setup_api_v1_std_fingerbank_routes($all_route, $upstream, $local_route, "MacVendors", "/mac_vendors", "/mac_vendor/#mac_vendor_id");
    $self->setup_api_v1_std_fingerbank_routes($all_route, $upstream, $local_route, "UserAgents", "/user_agents", "/user_agent/#user_agent_id");
    return ;
}

=head2 setup_api_v1_std_fingerbank_routes

setup_api_v1_std_fingerbank_routes

=cut

sub setup_api_v1_std_fingerbank_routes {
    my ($self, $all_route, $upstream_root, $local_root, $name, $collection_path, $resource_path) = @_;
    my $controller = "Fingerbank::${name}";
    $self->setup_api_v1_std_readonly_fingerbank_routes($all_route, $name, $controller, $collection_path, $resource_path);
    $self->setup_api_v1_std_readonly_fingerbank_routes($upstream_root, $name, $controller, $collection_path, $resource_path);
    $self->setup_api_v1_std_local_fingerbank_routes($local_root, $name, $controller, $collection_path, $resource_path);
    return ;
}

=head2 setup_api_v1_std_upstream_fingerbank_routes

setup_api_v1_std_upstream_fingerbank_routes

=cut

sub setup_api_v1_std_readonly_fingerbank_routes {
    my ($self, $root, $name, $controller, $collection_path, $resource_path) = @_;
    my $root_name = $root->name;
    my $collection_route = $root->any($collection_path)->to(controller => $controller )->name("${root_name}.${name}");
    $collection_route->register_sub_action({ method => 'GET', action => 'list', path => ''});
    $collection_route->register_sub_action({ method => 'POST', action => 'search'});
    my $resource_route = $root->under($resource_path)->to(controller=> $controller, action => "resource")->name("${root_name}.${name}.resource");
    $resource_route->register_sub_action({ method => 'GET', action => 'get', path => ''});
    return ;
}

=head2 setup_api_v1_std_local_fingerbank_routes

setup_api_v1_std_local_fingerbank_routes

=cut

sub setup_api_v1_std_local_fingerbank_routes {
    my ($self, $root, $name, $controller, $collection_path, $resource_path) = @_;
    my $root_name = $root->name;
    my $collection_route = $root->any($collection_path)->to(controller => $controller )->name("${root_name}.${name}");
    $collection_route->register_sub_action({ method => 'GET', action => 'list', path => ''});
    $collection_route->register_sub_action({ method => 'POST', action => 'create', path => '', auditable => 1});
    $collection_route->register_sub_action({ method => 'POST', action => 'search'});
    my $resource_route = $root->under($resource_path)->to(controller=> $controller, action => "resource")->name("${root_name}.${name}.resource");
    $resource_route->register_sub_action({ method => 'GET', action => 'get', path => ''});
    $resource_route->register_sub_action({ method => 'DELETE', action => 'remove', path => '', auditable => 1});
    $resource_route->register_sub_action({ method => 'PUT', action => 'replace', path => '', auditable => 1});
    $resource_route->register_sub_action({ method => 'PATCH', action => 'update', path => '', auditable => 1});
    return ;
}

=head2 setup_api_v1_config_wmi_rules_routes

setup_api_v1_config_wmi_rules_routes

=cut

sub setup_api_v1_config_wmi_rules_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::WMIRules",
        "/wmi_rules",
        "/wmi_rule/#wmi_rule_id",
        "api.v1.Config.WMIRules"
    );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_config_ssl_certificates_routes

setup_api_v1_config_ssl_certificates_routes

=cut

sub setup_api_v1_config_ssl_certificates_routes {
    my ($self, $root) = @_;
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $root,
        "Config::SSLCertificates",
        "/ssl_certificates",
        "/ssl_certificate/#ssl_certificate_id",
        "api.v1.Config.SSLCertificates"
    );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_config_filter_engines_routes

setup_api_v1_config_filter_engines_routes

=cut

sub setup_api_v1_config_filter_engines_routes {
    my ($self, $root) = @_;
    my $filter_engines_root = $root->any("/filter_engines")->name("api.v1.Config.FilterEngines");
    $filter_engines_root->register_sub_action(
        {
            method     => 'GET',
            action     => 'engines',
            path       => '',
            controller => 'Config::FilterEngines'
        }
    );
    my ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $filter_engines_root,
        "Config::FilterEngines::VlanFilters",
        "/vlan_filters",
        "/vlan_filter/#vlan_filter_id",
        "api.v1.Config.FilterEngines.Vlan"
      );

    ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $filter_engines_root,
        "Config::FilterEngines::DHCPFilters",
        "/dhcp_filters",
        "/dhcp_filter/#dhcp_filter_id",
        "api.v1.Config.FilterEngines.DHCP"
      );

    ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $filter_engines_root,
        "Config::FilterEngines::DNSFilters",
        "/dns_filters",
        "/dns_filter/#dns_filter_id",
        "api.v1.Config.FilterEngines.DNS"
      );

    ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $filter_engines_root,
        "Config::FilterEngines::RADIUSFilters",
        "/radius_filters",
        "/radius_filter/#radius_filter_id",
        "api.v1.Config.FilterEngines.RADIUS"
      );

    ($collection_route, $resource_route) =
      $self->setup_api_v1_std_config_routes(
        $filter_engines_root,
        "Config::FilterEngines::SwitchFilters",
        "/switch_filters",
        "/switch_filter/#switch_filter_id",
        "api.v1.Config.FilterEngines.Switch"
      );

    return ($collection_route, $resource_route);
}

=head2 setup_api_v1_config_system_routes

setup_api_v1_config_system_routes 

=cut

sub setup_api_v1_config_system_routes {
    my ($self, $root) = @_;
    $root->any( ['GET'] => "/system/gateway" )
      ->to(controller => "Config::System", action => "get_gateway")
      ->name("api.v1.Config.System.get_gateway");
    $root->any( ['PUT'] => "/system/gateway" )
      ->to(controller => "Config::System", action => "put_gateway")
      ->name("api.v1.System.put_gateway");
    
    $root->any( ['GET'] => "/system/hostname" )
      ->to(controller => "Config::System", action => "get_hostname")
      ->name("api.v1.Config.System.get_hostname");
    $root->any( ['PUT'] => "/system/hostname" )
      ->to(controller => "Config::System", action => "put_hostname")
      ->name("api.v1.Config.System.put_hostname");
    
    $root->any( ['GET'] => "/system/dns_servers" )
      ->to(controller => "Config::System", action => "get_dns_servers")
      ->name("api.v1.Config.System.get_dns_servers");
    $root->any( ['PUT'] => "/system/dns_servers" )
      ->to(controller => "Config::System", action => "put_dns_servers")
      ->name("api.v1.Config.System.put_dns_servers");
}

=head2 setup_api_v1_system_summary_route

setup_api_v1_system_summary_route

=cut

sub setup_api_v1_system_summary_route {
    my ($self, $root) = @_;
    $root->any( ['GET'] => "/system_summary" )
      ->to(controller => "SystemSummary", action => "get")
      ->name("api.v1.SystemSummary.get");
    return ;
}

=head2 setup_api_v1_configurator_routes

setup_api_v1_configurator_routes

=cut

sub setup_api_v1_configurator_routes {
    my ($self, $root) = @_;
    my $config = $root->under("/config")->name("api.v1.Configurator.Config");
    $self->setup_api_v1_config_bases_routes($config, 1);
    $self->setup_api_v1_config_fingerbank_settings_routes($config);
    $self->setup_api_v1_config_interfaces_routes($config);
    $self->setup_api_v1_config_system_routes($config);

    $self->setup_api_v1_translations_routes($root);
    $self->setup_api_v1_fingerbank_routes($root);
    $self->setup_api_v1_services_routes($root);
    $self->setup_api_v1_system_services_routes($root);
    $self->setup_api_v1_users_routes($root);

    return;
}

=head2 setup_api_v1_emails_route

setup_api_v1_emails_route

=cut

sub setup_api_v1_emails_route {
    my ($self, $root) = @_;
    my $resource_route = $root->any("email")->to(controller => "Emails" )->name("api.v1.Emails");
    $resource_route->register_sub_action({ method => 'POST', action => 'preview', path => 'preview'});
    $resource_route->register_sub_action({ method => 'POST', action => 'send_email', path => 'send'});
    $resource_route->register_sub_action({ method => 'POST', action => 'pfmailer', path => 'pfmailer'});
    return ;
}

=head1 AUTHOR

Inverse inc. <info@inverse.ca>

=head1 COPYRIGHT

Copyright (C) 2005-2020 Inverse inc.

=head1 LICENSE

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301,
USA.

=cut

1;
