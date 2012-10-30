package PlugAuth;

# ABSTRACT: Pluggable authentication and authorization server.
# VERSION

=head1 SYNOPSIS

In your /etc/PlugAuth.conf

 ---
 url: http://localhost:1234
 user_file: /etc/plugauth/user.txt
 group_file: /etc/plugauth/group.txt
 resource_file: /etc/plugauth/resource.txt
 host_file: /etc/plugauth/host.txt

Then create some users and groups

 % touch /etc/plugauth/user.txt \
         /etc/plugauth/group.txt \
         /etc/plugauth/resource.txt \
         /etc/plugauth/host.txt
 % plugauth start
 % plugauthclient create_user --user bob --password secret
 % plugauthclient create_user --user alice --password secret
 % plugauthclient create_group --group both --users bob,alice

In the configuration file for the Clustericious app
that will authenticate against PlugAuth:

 ---
 simple_auth:
   url: http://localhost:1234

and I<authenticate> and I<authorize> in your Clustericious app's Routes.pm:

 authenticate;
 authorize;
 
 get '/resource' => sub {
   # resource that requires authentication
   # and authorization
 };

=head1 DESCRIPTION

PlugAuth is a pluggable authentication and authorization server with a consistent
RESTful API.  This allows clients to authenticate and query authorization from a
PlugAuth server without worrying or caring whether the actual authentication happens
against flat files, PAM, LDAP or passed on to another PlugAuth server.

The authentication API is HTTP Basic Authentication.  The authorization API is based
on users, groups, resources and hosts.

The implementation for these can be swapped in and out depending on the plugins that
you select in the configuration file.  The default plugins for authentication 
(L<PlugAuth::Plugin::FlatAuth>) and authorization (L<PlugAuth::Plugin::FlatAuthz>) are
implemented with ordinary flat files and advisory locks using flock.

The are other plugins for ldap (L<PlugAuth::Plugin::LDAP>), L<DBI> 
(L<PlugAuth::Plugin::DBI::Auth>), or you can write your own (L<PlugAuth::Plugin>).

Here is a diagram that illustrates the most common use case for PlugAuth being used 
by a RESTful service:

  client
    |
    | HTTP
    |
 +-----------+          +------------+     +--------------+
 |   REST    |   HTTP   |            | --> | Auth Plugin  |  --> files
 |  service  |  ------> |  PlugAuth  |     +--------------+  --> ldap
 |           |          |            | --> | Authz Plugin |  --> ...
 +-----------+          +------------+     +--------------+

=over 4

=item 1.

Client (web browser or other) sends an  HTTP reqeust to the service.

=item 2

The service sends an HTTP basic auth request to PlugAuth with the user's credentials

=item 3

PlugAuth performs authentication (see L</AUTHENTICATION>) and returns the appropriate 
HTTP status code.

=item 4

The REST service sends the HTTP status code to the client if authentication has failed.

=item 5

The REST service may optionally check the client's host, and if it is "trusted", 
authorization succeeds (see L</AUTHORIZATION>).

=item 6

If not, the REST service sends an authorization request to PlugAuth, asking whether 
the client has permission to perform an "action" on a "resource". Both the action and 
resource are arbitrary strings, though one reasonable default is sending the HTTP 
method as the action, and the URL path as the resource.  (see L</AUTHORIZATION> below).

=item 7

PlugAuth returns a response code to the REST service indicating whether or not 
authorization should succeed.

=item 8

The REST service returns the appropriate response to the client.

=back

If the REST service uses Apache, see L<SimpleAuthHandler> for Apache 
authorization/authentication handlers.

If the REST service is written in Perl, see L<PlugAuth::Client>.

If the REST service uses Clustericious, see L<Clustericious::Plugin::SimpleAuth>.

=head2 AUTHENTICATION

Checking for authentication is done by sending a GET request to urls of the form

 /auth

With the username and password specified as HTTP Basic credentials.  The actual 
mechanism used to verify authentication will depend on the authentication plugin being 
used.  The default is L<PlugAuth::Plugin::Auth>.


=head2 AUTHORIZATION

Checking the authorization is done by sending GET requests to urls of the form

 /authz/user/user/action/resource

where I<user> and I<action> are strings (no slashes), and I<resource> is a string 
which may have slashes. A response code of 200 indicates that access should be 
granted, 403 indicates that the resource is forbidden.  A user is granted access to a 
resource if one of of the following conditions are met:

=over 4

=item

the user is specifically granted access to that resource, i.e. a line of the form

 /resource (action): username

appears in the resources file (see L</CONFIGURATION>).

=item

the user is a member of a group which is granted access to that resource.

=item

the user or a group containing the user is granted access to a resource which is a 
prefix of the requested resource.  i.e.

 / (action): username

would grant access to "username" to perform "action" on any resource.

=item

Additionally, given a user, an action, and a regular expression, it is possible to find 
I<all> of the resources matching that regular expression for which the user has access.  This
can be done by sending a GET request to

 /authz/resources/user/action/regex

=item

Host-based authorization is also possible -- sending a get
request to

    /host/host/trusted

where ".host" is a string representing a hostname, returns
200 if the host-based authorization should succeed, and
403 otherwise.

=back

=head2 CONFIGURATION

Server configuration is done in ~/etc/PlugAuth.conf which is a 
Clustericious::Config style file.  The configuration depends on which plugins you 
choose, consulte your plugin's documentation.  The default plugins are
L<PlugAuth::Plugin::Auth>, L<PlugAuth::Plugin::Authz>.

Once the authentication and authorization has been configured, PlugAuth
can be started (like any L<Mojolicious> or L<Clustericious> application)
using the daemon command:

 % plugauth daemon

This will use the built-in webserver.  To use another web server, additional
configuration is required.  For example, after adding this:

 start_mode: hypnotoad
 hypnotoad :
   listen : 'http://localhost:8099'
   env :
     %# Automatically generated configuration file
     HYPNOTOAD_CONFIG : /var/run/pluginauth/pluginauth.hypnotoad.conf

This start command can be used to start a hypnotoad webserver.

 % plugauth start
 
See L<Clustericious::Config> for more examples, including using with nginx,
lighttpd, Plack or Apache.

=head1 EVENTS

=head2 user_list_changed

Emitted when a user is created or deleted.

=head1 TODO

Apply authorization to the pluginauth server itself: currently anyone
can query about anyone else's authorization.

=head1 SEE ALSO

L<Clustericious::Plugin::SimpleAuth>,
L<PlugAuth::Client>,
L<PlugAuth::Plugin::Auth>,
L<PlugAuth::Plugin::Authz>,
L<PlugAuth::Plugin>

=cut

use strict;
use warnings;
use v5.10;
use base 'Clustericious::App';
use PlugAuth::Routes;
use Log::Log4perl qw( :easy );
use Role::Tiny ();
use PlugAuth::Role::Plugin;
use Clustericious::Config;
use Mojo::Base 'Mojo::EventEmitter';

sub startup {
    my $self = shift;
    $self->SUPER::startup(@_);
    $self->plugin('Subdispatch');

    my @plugins_config = eval {
        my $plugins = $self->config->plugins(default => []);
        ref($plugins) ? @$plugins : ($plugins);
    };

    my $auth_plugin;
    my $authz_plugin;
    my @refresh;
    
    foreach my $plugin_class (reverse @plugins_config) {

        my $plugin_config;
        if(ref $plugin_class) {
            ($plugin_config) = values %$plugin_class;
            $plugin_config = Clustericious::Config->new($plugin_config);
            ($plugin_class)  = keys %$plugin_class;
        } else {
            $plugin_config = Clustericious::Config->new({});
        }
        
        eval qq{ require $plugin_class };
        LOGDIE $@ if $@;
        Role::Tiny::does_role($plugin_class, 'PlugAuth::Role::Plugin')
            || LOGDIE "$plugin_class is not a PlugAuth plugin";
        
        my $plugin = $plugin_class->new($self->config, $plugin_config, $self);

        if($plugin->does('PlugAuth::Role::Auth')) {
          $plugin->next_auth($auth_plugin);
          $auth_plugin = $plugin;
        }

        $authz_plugin = $plugin if $plugin->does('PlugAuth::Role::Authz');
        push @refresh, $plugin if $plugin->does('PlugAuth::Role::Refresh')
    }

    unless(defined $auth_plugin) {
        require PlugAuth::Plugin::FlatAuth;
        if($self->config->ldap(default => '')) {
            require PlugAuth::Plugin::LDAP;
            $auth_plugin = PlugAuth::Plugin::LDAP->new($self->config, {}, $self);
            $auth_plugin->next_auth(PlugAuth::Plugin::FlatAuth->new($self->config, Clustericious::Config->new({}), $self));
            push @refresh, $auth_plugin->next_auth;
            
        } else {
            $auth_plugin = PlugAuth::Plugin::FlatAuth->new($self->config, Clustericious::Config->new({}), $self);
            push @refresh, $auth_plugin;
        }
    }
    
    unless(defined $authz_plugin) {
        require PlugAuth::Plugin::FlatAuthz;
        $authz_plugin = PlugAuth::Plugin::FlatAuthz->new($self->config, Clustericious::Config->new({}), $self);
        push @refresh, $authz_plugin;
    }

    $self->helper(data  => sub { $auth_plugin  });
    $self->helper(auth  => sub { $auth_plugin  });
    $self->helper(authz => sub { $authz_plugin });
    
    if(@refresh > 0 ) {
        $self->helper(refresh => sub { $_->refresh for @refresh; 1 });
    } else {
        $self->helper(refresh => sub { 1 });
    }
}

# Silence warnings; this is only used for for session
# cookies, which we don't use.
__PACKAGE__->secret(rand);

1;

