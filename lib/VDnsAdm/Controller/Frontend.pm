package VDnsAdm::Controller::Frontend;

use base 'CGI::Application';

use strict;
use warnings;

use CGI::Carp qw(fatalsToBrowser);

use Encode;

# Needed for database connection
use CGI::Application::Plugin::DBH (qw/dbh_config dbh/);
use CGI::Application::Plugin::Redirect;
use CGI::Application::Plugin::Session;
use CGI::Application::Plugin::TT;
use CGI::Application::Plugin::RequireSSL;
use CGI::Application::Plugin::Authentication;

use Config::Std;
use DBI;
use Readonly;
use Try::Tiny;

use VWebAdm::Utils '@VERSION@';
use VDnsAdm::L10N '@VERSION@';
use VWebAdm::SaltedHash '@VERSION@';
use Log::Tree '@VERSION@';

use VWebAdm::Model::MessageQueue '@VERSION@';

use VDnsAdm::Model::User '@VERSION@';
use VDnsAdm::Model::Domain '@VERSION@';
use VDnsAdm::Model::Record '@VERSION@';
use VDnsAdm::Model::Group '@VERSION@';
use VDnsAdm::Model::Template '@VERSION@';
use VDnsAdm::Model::TemplateRecord '@VERSION@';

our $VERSION = '@VERSION@';

Readonly my $ENTRIES_PER_PAGE => 20;

############################################
# Usage      : Invoked by CGIApp
# Purpose    : Setup the Application
# Returns    : Nothing
# Parameters : None
# Throws     : no exceptions
# Comments   : none
# See Also   : n/a
# setup is run right after cgiapp_init
sub setup {
    my $self = shift;

    my $Logger = Log::Tree::->new('VDnsAdm/Frontend');
    $self->{'logger'} = $Logger;

    # define the default run mode
    $self->start_mode('public_login');

    # define the mappings between the rm parameter and the actual sub
    $self->run_modes(

        #
        # Public
        #
        'public_login' => 'show_login',

        #
        # Private
        #

        # General
        'welcome' => 'show_welcome',

        # Domains
        'domains'       => 'show_domains',
        'domain'        => 'show_domain',
        'create_domain' => 'show_create_domain',
        'add_domain'    => 'show_add_domain',
        'remove_domain' => 'show_remove_domain',
        'edit_domain'   => 'show_edit_domain',
        'update_domain' => 'show_update_domain',

        # Records
        'records'       => 'show_records',
        'create_record' => 'show_create_record',
        'add_record'    => 'show_add_record',
        'remove_record' => 'show_remove_record',
        'edit_record'   => 'show_edit_record',
        'update_record' => 'show_update_record',

        # Log
        'log' => 'show_log',

        # Admins
        'users'       => 'show_users',
        'user'        => 'show_user',
        'create_user' => 'show_create_user',
        'add_user'    => 'show_add_user',
        'remove_user' => 'show_remove_user',
        'edit_user'   => 'show_edit_user',
        'update_user' => 'show_update_user',

        # Groups
        'groups'       => 'show_groups',
        'create_group' => 'show_create_group',
        'add_group'    => 'show_add_group',
        'remove_group' => 'show_remove_group',
        'edit_group'   => 'show_edit_group',
        'update_group' => 'show_update_group',

        # Templates
        'templates'       => 'show_templates',
        'template'        => 'show_template',
        'create_template' => 'show_create_template',
        'add_template'    => 'show_add_template',
        'remove_template' => 'show_remove_template',
        'edit_template'   => 'show_edit_template',
        'update_template' => 'show_update_template',

        # TemplateRecords
        'template_records'       => 'show_template_records',
        'template_record'        => 'show_template_record',
        'create_template_record' => 'show_create_template_record',
        'add_template_record'    => 'show_add_template_record',
        'remove_template_record' => 'show_remove_template_record',
        'edit_template_record'   => 'show_edit_template_record',
        'update_template_record' => 'show_update_template_record',
    );

    # Authentication
    # Setup authentication using CGI::Application::Plugin::Authentication
    # Since we want to be able to support salted passwords, this is a bit messy.
    #
    # Contraints:
    # Only users who are either siteadmin or domainadmin should be able to login
    # and their account (= mailbox) must be active. Furthermore the username is
    # local_part@domain but those are stored in two different tables. So
    # we need to join those tables by specifying two tables and CONCAT the
    # fields together.
    #
    # Since the plugin does not support OR contraints we have to work around that issue.
    # In doubt I suggest to have a look the source code of the plugin.
    #
    # Filters:
    # The filter receives the user supplied password and the content of the column it is
    # applied to, extracts the pwscheme and salt, hashes the user supplied pass and returns
    # the password hash computed with the old salt and pwscheme. The plugin compares
    # the result with the unmodified column entry.
    $self->authen->config(
        DRIVER => [
            'DBI',
            TABLES      => [ 'users', 'domains' ],
            CONSTRAINTS => {
                "CONCAT(users.local_part,'\@',domains.name)" => '__CREDENTIAL_1__',
                'users.is_active'                            => '1',
                'domains.is_active'                          => '1',

                # WARNING: This contraint relies on an implementation detail of Plugin::Authentication!
                # This is bad style, but there is no other way right now.
                # The correct way would probably to create a custom Authen plugin.
                '(users.is_siteadmin OR users.is_domainadmin) AND 1' => '1',
            },
            COLUMNS => { 'dovecotpw:users.password' => '__CREDENTIAL_2__', },
            FILTERS => {
                'dovecotpw' => sub {

                    # since we may use salted passwords, we have to do our own
                    # password verification. a simple string eq would not do.
                    my $param   = shift;    # unused, always empty
                    my $plain   = shift;    # password from user
                    my $pwentry = shift;    # password hash from db
                    my ( $pwscheme, undef, $salt ) = &VWebAdm::SaltedHash::split_pass($pwentry);
                    my $passh = &VWebAdm::SaltedHash::make_pass( $plain, $pwscheme, $salt );
                    return $passh;
                },
            }
        ],
        LOGOUT_RUNMODE      => 'public_login',
        LOGIN_RUNMODE       => 'public_login',
        POST_LOGIN_CALLBACK => \&post_login_callback,
    );

    # only enable authen if called as CGI, this helps with testing and debugging from the commandline
    if ( !$self->is_shell() ) {
        $self->authen->protected_runmodes(qr/^(?!public_|api)/);
    }

    #
    # Configuration
    #
    # Valid config file locations to try
    my @conffile_locations = qw(
      vdnsadm.conf
      conf/vdnsadm.conf
      /etc/vdnsadm/vdnsadm.conf
      @CFGDIR@/vdnsadm/vdnsadm.conf
    );

    # if the application if run as a FastCGI app, the server might
    # provide an additional configuration location. if the points to file
    # add it to the list of possible locations
    if ( $ENV{CGIAPP_CONFIG_FILE} && -f $ENV{CGIAPP_CONFIG_FILE} ) {
        unshift( @conffile_locations, $ENV{CGIAPP_CONFIG_FILE} );
    }

    my ( %config, $conffile_used );

    # Try all config file locations
    foreach my $loc (@conffile_locations) {
        if ( -r $loc ) {
            $conffile_used = $loc;
            read_config $loc => %config;
            last;
        }
    }
    if ( !$conffile_used ) {
        $self->log( "Warning: No readable config file found in search path! (" . join( ':', @conffile_locations ) . ")", 'warning', );
    }
    $self->{config} = \%config;

    #
    # Database
    #
    my $user = $config{'default'}{'dbuser'} || 'root';
    my $pass = $config{'default'}{'dbpass'} || 'root';
    my $db   = $config{'default'}{'dbdb'}   || 'vdnsadm';
    my $port = $config{'default'}{'dbport'} || 3306;
    my $host = $config{'default'}{'dbhost'} || 'localhost';
    my $dsn  = "DBI:mysql:database=$db;user=$user;password=$pass;host=$host;port=$port";
    $self->{base_url}     = $config{'cgi'}{'base_url'}     || '/cgi-bin/vdnsadm.pl';
    $self->{media_prefix} = $config{'cgi'}{'media_prefix'} || '';

    # Connect to DBI database, same args as DBI->connect();
    # uses connect_cached for persistent connections
    # this should have no effect for CGI and speed up FastCGI
    # http://www.cosmocode.de/en/blog/gohr/2009-12/10-surviving-the-perl-utf-8-madness
    # http://www.gyford.com/phil/writing/2008/04/25/utf8_mysql_perl.php
    # http://stackoverflow.com/questions/6162484/why-does-modern-perl-avoid-utf-8-by-default
    # mysql_enable_utf8 should prepare the connection for UTF-8. It will also SET NAMES utf8.
    # Scripts, Database, Sourcecode, Userdata ... everything should be in UTF-8
    # the only point were we could deal with non-UTF-8 is when we output data to
    # non-utf-8 capable browsers (are there any?)
    $self->dbh_config(
        sub {
            DBI->connect_cached(
                $dsn, undef, undef,
                {
                    PrintError        => 0,
                    RaiseError        => 0,
                    mysql_enable_utf8 => 1,
                }
            );
        }
    );
    if ( !$self->dbh ) {
        $self->log( "Failed to establish DB connection with DSN $dsn and error message: " . DBI->errstr, 'error', );
        die("Could not connect to DB.");
    }

    #
    # L10N
    #
    # the user handle, will try to determine the appropriate language ... look at the docs of Locale::Maketext
    $self->{lh} = VDnsAdm::L10N->get_handle();

    # this handle is used for logging. logged messages should always be in english
    $self->{lh_en} = VDnsAdm::L10N->get_handle('en');

    #
    # Templating unsing the Template Toolkit
    #
    # Filters:
    # Have a look at the docs of the tt for info on dynamic filters.
    # Short version: they allow filters with more than one argument.
    # highlight provides syntax highlightning for the search
    # l10n provides localization via Locale::Maketext
    my @include_path = qw(tpl/ ../tpl/ /usr/lib/vwebadm/tpl);
    if ( $config{'cgi'}{'template_path'} && -d $config{'cgi'}{'template_path'} ) {
        unshift( @include_path, $config{'cgi'}{'template_path'} );
    }
    $self->tt_config(
        TEMPLATE_OPTIONS => {
            ENCODING     => 'utf8',
            INCLUDE_PATH => \@include_path,
            POST_CHOMP   => 1,
            FILTERS      => {
                'currency' => sub { sprintf( '%0.2f', @_ ) },

                # dynamic filter factory, see TT manpage
                'highlight' => [
                    sub {
                        my ( $context, $search ) = @_;

                        return sub {
                            my $str = shift;
                            if ($search) {
                                $str =~ s/($search)/<span class='hilighton'>$1<\/span>/g;
                            }
                            return $str;
                          }
                    },
                    1
                ],

                # A localization filter. Turn the english text into the localized counterpart using Locale::Maketext
                'l10n' => [
                    sub {
                        my ( $context, @args ) = @_;

                        return sub {
                            my $str = shift;
                            return $self->{lh}->maketext( $str, @args );
                          }
                    },
                    1,
                ],
            }
        }
    );
    $self->tt_params( base_url     => $self->{base_url} );
    $self->tt_params( media_prefix => $self->{media_prefix} );

    # setup classes if the user is logged in
    if ( $self->authen->is_authenticated && $self->authen->username ) {
        my $Messages = VWebAdm::Model::MessageQueue::->new(
            {
                'lh'      => $self->{'lh'},
                'lh_en'   => $self->{'lh_en'},
                'session' => $self->session,
                'logger'  => $Logger,
            }
        );

        # if we can not create a new user object we MUST NOT die but redirect to login page instead
        my $User;
        eval {
            $User = VDnsAdm::Model::User::->new(
                {
                    'dbh'      => $self->dbh,
                    'username' => $self->authen->username,
                    'force'    => 1,
                    'msgq'     => $Messages,
                    'logger'   => $Logger,
                    'config'   => $self->{'config'},
                }
            );
            $User->login('forced-login');
        };
        if ( $@ || !$User ) {
            $self->log("Could not create User Object: $@");
        }
        else {
            $self->{'Messages'} = $Messages;
            $self->{'User'}     = $User;
            my $arg_ref = {
                'dbh'    => $self->dbh,
                'user'   => $User,
                'msgq'   => $Messages,
                'logger' => $Logger,
                'config' => $self->{'config'},
            };
            $self->{'Domain'}         = VDnsAdm::Model::Domain::->new($arg_ref);
            $arg_ref->{'domain'}      = $self->{'Domain'};
            $self->{'Record'}         = VDnsAdm::Model::Record::->new($arg_ref);
            $arg_ref->{'record'}      = $self->{'Record'};
            $self->{'Template'}       = VDnsAdm::Model::Template::->new($arg_ref);
            $arg_ref->{'template'}    = $self->{'Template'};
            $self->{'TemplateRecord'} = VDnsAdm::Model::TemplateRecord::->new($arg_ref);
            $self->{'Group'}          = VDnsAdm::Model::Group::->new($arg_ref);
        }
    }
    else {
        $Logger->log( message => 'User is not authenticated.', level => 'error', );
    }

    # to make perlcritic happy
    return 1;
}

sub teardown {
    my $self = shift;

    # Disconnect when done
    $self->dbh->disconnect();

    # to make perlcritic happy
    return 1;
}

#
# CGI::Application Hooks
#
# cgiapp_init is run right before setup
sub cgiapp_init {
    my $self = shift;

    # Everything should be in UTF-8!
    $self->query->charset('UTF-8');

    # Configure RequireSSL
    my $ignore_ssl_check = 0;
    if ( $self->is_shell() || $self->is_localnet() || $self->{config}{'cgi'}{'no_ssl'} ) {
        $ignore_ssl_check = 1;
    }

    $self->config_requiressl(
        'keep_in_ssl'  => 1,
        'ignore_check' => $ignore_ssl_check,
    );

    # to make perlcritic happy
    return 1;
}

#
# Template::Toolkit Hooks
#

# post processing hooks
sub tt_post_process {
    my $self    = shift;
    my $htmlref = shift;

    # nop
    return;
}

# pre processing set commonly used variables for the templates
sub tt_pre_process {
    my ( $self, $file, $vars ) = @_;

    $vars->{username}                 = $self->authen->username;
    $vars->{system_domain}            = $self->{config}{'default'}{'domain'} || 'localhost';
    $vars->{long_forms}               = $self->{config}{'cgi'}{'long_forms'} || 0;
    $vars->{version}                  = $VERSION;
    $vars->{messages}                 = $self->get_messages();
    $vars->{is_siteadmin}             = $self->user->is_siteadmin() if $self->user();
    $vars->{is_domainadmin}           = $self->user->is_domainadmin() if $self->user();
    $vars->{product}                  = 'VDnsAdm';
    $vars->{product_url}              = 'http://www.vdnsadm.net/';
    $vars->{feature_groups}           = $self->{config}{'default'}{'feature_groups'} || 0;
    $vars->{feature_templates}        = $self->{config}{'default'}{'feature_templates'} || 0;
    $vars->{feature_linked_templates} = $self->{config}{'default'}{'feature_linked_templates'} || 0;

    return;
}

#
# Misc. private Subs
#

############################################
# Usage      : $self->log('message');
# Purpose    : Log a message to the log table and syslog
# Returns    : true on success
# Parameters : a string
# Throws     : no exceptions
# Comments   : none
# See Also   : n/a
sub log {
    my $self     = shift;
    my $msg      = shift;
    my $severity = shift || 'debug';

    # Get our database connection
    my $dbh = $self->dbh();

    if ($msg) {
        my $caller = ( caller(1) )[3] || 'n/a';
        $self->{'logger'}->log( message => $msg, level => $severity, 'caller' => $caller );
        my $query = "INSERT INTO log (ts,msg) VALUES(NOW(),?)";
        my $sth   = $dbh->prepare($query)
          or $self->{'logger'}->log( message => 'Could not prepare Query: ' . $query . ', Error: ' . DBI->errstr );
        if ( $sth->execute($msg) ) {
            $sth->finish();
            return 1;
        }
        else {
            $self->{'logger'}->log( message => 'Could not execute Query: ' . $query . ', Args: ' . $msg . ', Error: ' . $sth->errstr );
            $sth->finish();
            return;
        }
    }
    else {
        return;
    }
}

############################################
# Usage      : called by Authentication plugin after successfull login
# Purpose    : log login and setup user env.
# Returns    : always true
# Parameters : none
# Throws     : no exceptions
# Comments   : none
# See Also   : n/a
sub post_login_callback {
    my $self = shift;

    $self->log_login();

    return 1;
}

############################################
# Usage      : $self->log_login();
# Purpose    : convenience method for logging a user login event
# Returns    : always true
# Parameters : none
# Throws     : no exceptions
# Comments   : none
# See Also   : n/a
sub log_login {
    my $self = shift;
    return unless ( $self->authen->is_authenticated );
    $self->log( "User " . $self->authen->username . " logged in.", );
    return 1;
}

############################################
# Usage      : $self->add_message('warning','message');
# Purpose    : Add a message to the notification message stack
# Returns    : always true
# Parameters : the type and the message
# Throws     : no exceptions
# Comments   : none
# See Also   : n/a
# add entry to notify
sub add_message {
    my $self = shift;
    my $type = shift;
    my $msg  = shift;
    return unless $type && $msg;
    return if !$self->{'Messages'};
    $self->{'Messages'}->push( $type, $msg );
    return 1;
}

############################################
# Usage      : $self->get_messages();
# Purpose    : Return all messages from the message stack and remove them
# Returns    : a hashref w/ the messages by priority
# Parameters : none
# Throws     : no exceptions
# Comments   : none
# See Also   : n/a
# get and reset notify
sub get_messages {
    my $self = shift;
    return if !$self->{'Messages'};
    my @msgs = $self->{'Messages'}->pop();
    return \@msgs;
}

############################################
# Usage      : $self->peek_message();
# Purpose    : Return the message stack w/o removing the messages
# Returns    : a hashref w/ the message by priority
# Parameters : none
# Throws     : no exceptions
# Comments   : none
# See Also   : n/a
# get notify (no reset)
sub peek_message {
    my $self = shift;
    return if !$self->{'Messages'};
    my @msgs = $self->{'Messages'}->peek();
    return \@msgs;
}

############################################
# Usage      : $self->is_shell()
# Purpose    : is the script run from a shell?
# Returns    : true if no CGI
# Parameters : none
# Throws     : no exceptions
# Comments   : none
# See Also   : n/a
sub is_shell {
    my $self = shift;
    if ( $ENV{'DISPLAY'} && $ENV{'PS1'} && $ENV{'SHELL'} && $ENV{'USER'} ) {
        if (   $ENV{'DOCUMENT_ROOT'}
            || $ENV{'GATEWAY_INTERFACE'}
            || $ENV{'HTTP_HOST'}
            || $ENV{'REMOTE_ADDR'}
            || $ENV{'REQUEST_METHOD'}
            || $ENV{'SERVER_SOFTWARE'} )
        {
            return;
        }
        else {
            return 1;
        }
    }
    else {
        return;
    }
}

sub user {
    my $self = shift;
    return $self->{'User'};
}

############################################
# Usage      : $self->is_localnet()
# Purpose    : tell if the user is on a local, i.e. somewhat trusted, network
# Returns    : true if localnet or shell
# Parameters : none
# Throws     : no exceptions
# Comments   : none
# See Also   : n/a
sub is_localnet {
    if ( !$ENV{'REMOTE_ADDR'} ) {
        return 1;    # shell, coz' local
    }
    else {
        if ( $ENV{'REMOTE_ADDR'} =~ m/^(192\.168|172\.(1[6-9]|2\d|3[0-1])|10)\./ ) {
            return 1;
        }
        else {
            return;
        }
    }
}

############################################
# Usage      :
# Purpose    : Return the domain name to a given domain id.
# Returns    :
# Parameters :
# Throws     : no exceptions
# Comments   : none
# See Also   : n/a
sub get_domain_byid {
    my $self      = shift;
    my $domain_id = shift;

    return $self->{'Domain'}->get_name($domain_id);
}

#
# Public
#

sub show_login {
    my $self = shift;

    $self->session_delete();

    my %params = (
        title        => $self->{lh}->maketext('VDnsAdm Login'),
        nonavigation => 1,
    );

    return $self->tt_process( 'vwebadm/login.tpl', \%params );
}

#
# Private
#

#
# General / Misc.
#
sub show_welcome {
    my $self = shift;

    my %params = (
        'title'   => $self->{lh}->maketext('VDnsAdm Overview'),
        'current' => 'welcome',
    );

    return $self->tt_process( 'vdnsadm/welcome.tpl', \%params );
}

#
# Domains
#

sub show_domains {
    my $self = shift;

    # Get our database connection
    my $dbh = $self->dbh();

    # Get CGI Query object
    my $q = $self->query();

    my $page   = $q->param('page') || 1;
    my $search = $q->param('search');
    my %params = ( 'Search' => $search, );

    my $sql_records = "SELECT COUNT(*) FROM records WHERE domain_id = ? AND type <> 'SOA'";
    my $sth_records = $dbh->prepare($sql_records);

    my @domains = $self->{'Domain'}->list( \%params );

    foreach my $domain (@domains) {
        if ( $sth_records->execute( $domain->{'id'} ) ) {
            $domain->{'num_records'} = $sth_records->fetchrow_array();
        }
    }

    $sth_records->finish();

    my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) = localtime(time);
    $year += 1900;
    $mon++;
    my $serial = sprintf( "%4d%02d%02d%02d", $year, $mon, $mday, 1 );

    my @groups    = ();
    my @templates = ();

    if ( $self->{config}{'default'}{'feature_groups'} ) {
        @groups = $self->{'Group'}->list();
    }

    if ( $self->{config}{'default'}{'feature_templates'} ) {
        @templates = $self->{'Template'}->list();
        unshift( @templates, { 'id' => 0, 'name' => 'None', } );
    }

    %params = (
        'title'      => $self->{lh}->maketext('VDnsAdm Domains'),
        'current'    => 'domains',
        'domains'    => \@domains,
        'search'     => $search,
        'soa_serial' => $serial,
        'groups'     => \@groups,
        'templates'  => \@templates,
    );

    return $self->tt_process( 'vdnsadm/domain/list.tpl', \%params );
}

sub show_domain {
    my $self = shift;

    if ( !$self->user->is_siteadmin() ) {
        my $msg = "You are not authorized to access this page.";
        $self->log( $msg . ". User: " . $self->authen->username );
        $self->add_message( 'error', $self->{lh}->maketext($msg) );
        $self->redirect( $self->{base_url} . '?rm=welcome' );
        return;
    }

    # Get our database connection
    my $dbh = $self->dbh();

    # Get CGI Query object
    my $q = $self->query();

    my $domain_id = $q->param('domain_id') || undef;

    if ( !$domain_id || $domain_id !~ m/^\d+$/ ) {
        my $msg = "Invalid Domain-ID.";
        $self->log( $msg . ". User: " . $self->authen->username );
        $self->add_message( 'error', $msg );
        $self->redirect( $self->{base_url} . '?rm=welcome' );
        return;
    }

    my $params = {};

    # Authorization
    if ( !$self->user->is_siteadmin() && $self->user->is_domainadmin() ) {
        $params->{'domain_id'} = $self->user->get_domain_id();
    }

    my $sql = undef;
    my $sth = undef;

    # Get Domain name
    my $domain_ref  = $self->{'Domain'}->read($domain_id);
    my $domain_name = $domain_ref->{'name'};

    # Get Records
    my @records = $self->{'Record'}->list( { 'domain_id' => $domain_id, 'NotType' => 'SOA', }, );
    my @types   = $self->{'Record'}->types();
    my @domains = $self->{'Domain'}->list($params);

    my %params = (
        'title'     => $self->{lh}->maketext( 'VDnsAdm Domain: [_1]', $domain_name ),
        'current'   => 'domains',
        'domain'    => $domain_name,
        'records'   => \@records,
        'types'     => \@types,
        'domains'   => \@domains,
        'domain_id' => $domain_id,
    );

    return $self->tt_process( 'vdnsadm/domain/show.tpl', \%params );
}

sub show_create_domain {
    my $self = shift;

    if ( !$self->user->is_siteadmin() ) {
        my $msg = "You are not authorized to access this page.";
        $self->log( $msg . ". User: " . $self->authen->username );
        $self->add_message( 'error', $self->{lh}->maketext($msg) );
        $self->redirect( $self->{base_url} . '?rm=welcome' );
        return;
    }

    my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst ) = localtime(time);
    $year += 1900;
    $mon++;
    my $serial = sprintf( "%4d%02d%02d%02d", $year, $mon, $mday, 1 );

    my @groups    = ();
    my @templates = ();

    if ( $self->{config}{'default'}{'feature_groups'} ) {
        @groups = $self->{'Group'}->list();
    }

    if ( $self->{config}{'default'}{'feature_templates'} ) {
        @templates = $self->{'Template'}->list();
        unshift( @templates, { 'id' => 0, 'name' => 'None', } );
    }

    my %params = (
        'title'      => $self->{lh}->maketext('Add Domain'),
        'soa_serial' => $serial,
        'current'    => 'domains',
        'groups'     => \@groups,
        'templates'  => \@templates,
    );

    return $self->tt_process( 'vdnsadm/domain/create.tpl', \%params );
}

sub show_add_domain {
    my $self = shift;

    # Get CGI Query object
    my $q = $self->query();

    my $domain = &VWebAdm::Utils::trim( lc( $q->param('domain') ) );
    my $group  = &VWebAdm::Utils::trim( $q->param('group_id') );

    if ( my $domain_id =
        $self->{'Domain'}
        ->create( { 'name' => $domain, 'type' => 'MASTER', 'last_check' => 1, 'notified_serial' => 1, 'is_active' => 1, 'group_id' => $group, }, ) )
    {
        $self->log( 'Added Domain ' . $domain );

        # Create the SOA record
        my $soa_mname = $q->param('soa_mname');
        my $soa_rname = $q->param('soa_rname');
        $soa_rname =~ s/@/./;
        my $soa_serial  = $q->param('soa_serial');
        my $soa_refresh = $q->param('soa_refresh');
        my $soa_retry   = $q->param('soa_retry');
        my $soa_expire  = $q->param('soa_expire');
        my $soa_minimum = $q->param('soa_minimum');
        my $content     = join( ' ', ( $soa_mname, $soa_rname, $soa_serial, $soa_refresh, $soa_retry, $soa_expire, $soa_minimum ) );
        my $params      = {
            'ttl'       => $q->param('soa_ttl'),
            'prio'      => 0,
            'content'   => $content,
            'type'      => 'SOA',
            'domain_id' => $domain_id,
        };

        if ( $self->{'Record'}->create($params) ) {
            $self->log( 'Created SOA record for Domain ' . $domain . ' (' . $domain_id . ')' );
        }
        else {
            $self->log( 'Failed to create SOA record for Domain ' . $domain . ' (' . $domain_id . ')' );
            $self->add_message( 'error', 'Database Error when adding SOA!' );
        }
    }
    else {
        $self->log( 'Failed to add Domain ' . $domain );
        $self->add_message( 'error', 'Database Error!' );
    }

    $self->redirect( $self->{base_url} . '?rm=domains' );
    return;
}

sub show_remove_domain {
    my $self = shift;

    # Get CGI Query object
    my $q = $self->query();

    my $domain_id = $q->param('domain_id');

    if ( $self->{'Domain'}->delete($domain_id) ) {
        $self->log( 'Deleted Domain #' . $domain_id );
    }
    else {
        $self->log( 'Failed to delete Domain #' . $domain_id );
        $self->add_message( 'error', 'Database Error!' );
    }

    $self->redirect( $self->{base_url} . '?rm=domains' );
    return;
}

sub show_edit_domain {
    my $self = shift;

    if ( !$self->user->is_admin() ) {
        my $msg = "You are not authorized to access this page.";
        $self->log( $msg . ". User: " . $self->authen->username );
        $self->add_message( 'error', $self->{lh}->maketext($msg) );
        $self->redirect( $self->{base_url} . '?rm=welcome' );
        return;
    }

    # Get our database connection
    my $dbh = $self->dbh();

    # Get CGI Query object
    my $q = $self->query();

    my $large_content = $q->param('large') || 0;

    my $domain_id   = $q->param('domain_id');
    my $domain_ref  = $self->{'Domain'}->read($domain_id);
    my $domain_name = $domain_ref->{'name'};
    my ($soa_ref)   = $self->{'Record'}->list(
        {
            'Type'      => 'SOA',
            'domain_id' => $domain_id,
        }
    );

    my %params = (
        'title'         => $self->{lh}->maketext('Edit Domain'),
        'domain_id'     => $domain_id,
        'domain_name'   => $domain_name,
        'current'       => 'domains',
        'large_content' => $large_content,
    );

    foreach my $key ( keys %{$domain_ref} ) {
        $params{$key} = $domain_ref->{$key};
    }

    # SOA
    $params{'soa_id'}  = $soa_ref->{'id'};
    $params{'soa_ttl'} = $soa_ref->{'ttl'};
    my @soa_fields = qw(soa_mname soa_rname soa_serial soa_refresh soa_retry soa_expire soa_minimum);
    my @soa = split /\s+/, $soa_ref->{'content'};
    @params{@soa_fields} = @soa;

    # replace the first dot by the correct @
    $params{'soa_rname'} = join( '@', split /\./, $params{'soa_rname'}, 2 );

    return $self->tt_process( 'vdnsadm/domain/edit.tpl', \%params );
}

sub show_update_domain {
    my $self = shift;

    # Get CGI Query object
    my $q = $self->query();

    my $domain_id = $q->param('domain_id');

    # set params
    my $params = {};
    foreach my $field ( @{ $self->{'Domain'}->fields() } ) {
        next if $field eq 'id';
        $params->{$field} = $q->param($field) if defined( $q->param($field) );
    }
    if ( defined( $params->{'is_active'} ) ) {
        if ( $params->{'is_active'} eq 'on' ) {
            $params->{'is_active'} = 1;
        }
        else {
            $params->{'is_active'} = 0;
        }
    }

    if ( $self->{'Domain'}->update( $domain_id, $params ) ) {
        $self->log( 'Updated Domain #' . $domain_id );

        # Assemble the SOA record
        my $soa_id    = $q->param('soa_id');
        my $soa_mname = $q->param('soa_mname');
        my $soa_rname = $q->param('soa_rname');
        $soa_rname =~ s/@/./;
        my $soa_serial  = $q->param('soa_serial');
        my $soa_refresh = $q->param('soa_refresh');
        my $soa_retry   = $q->param('soa_retry');
        my $soa_expire  = $q->param('soa_expire');
        my $soa_minimum = $q->param('soa_minimum');
        my $content     = join( ' ', ( $soa_mname, $soa_rname, $soa_serial, $soa_refresh, $soa_retry, $soa_expire, $soa_minimum ) );
        my $params      = {
            'ttl'     => $q->param('soa_ttl'),
            'prio'    => 0,
            'content' => $content,
            'type'    => 'SOA',
        };

        if ( $self->{'Record'}->update( $soa_id, $params ) ) {
            $self->log( 'Updated SOA Record for Domain #' . $domain_id );
        }
        else {
            $self->log( 'Failed to update SOA Record for Domain #' . $domain_id );
        }
    }
    else {
        $self->log( 'Failed to update Domain #' . $domain_id );
        $self->add_message( 'error', 'Database Error!' );
    }

    $self->redirect( $self->{base_url} . '?rm=domains' );
    return;
}

#
# Records
#

sub show_records {
    my $self = shift;

    # Get our database connection
    my $dbh = $self->dbh();

    # Get CGI Query object
    my $q = $self->query();

    my $page = $q->param('page') || 1;
    my $search = $q->param('search');

    my $params = {};

    # Authorization
    if ( !$self->user->is_siteadmin() && $self->user->is_domainadmin() ) {
        $params->{'domain_id'} = $self->user->get_domain_id();
    }

    my @types   = $self->{'Record'}->types();
    my @domains = $self->{'Domain'}->list($params);
    $params->{'Search'} = $search if $search;
    my @records = $self->{'Record'}->list($params);

    my %params = (
        'title'   => $self->{lh}->maketext('VDnsAdm Records'),
        'current' => 'records',
        'records' => \@records,
        'domains' => \@domains,
        'types'   => \@types,
        'search'  => $search,
    );

    return $self->tt_process( 'vdnsadm/record/list.tpl', \%params );
}

sub show_create_record {
    my $self = shift;

    if ( !$self->user->is_admin() ) {
        my $msg = "You are not authorized to access this page.";
        $self->log( $msg . ". User: " . $self->authen->username );
        $self->add_message( 'error', $self->{lh}->maketext($msg) );
        $self->redirect( $self->{base_url} . '?rm=welcome' );
        return;
    }

    # Get CGI Query object
    my $q = $self->query();

    my $large_content = $q->param('large') || 0;

    my $params = {};

    # Authorization
    if ( !$self->user->is_siteadmin() && $self->user->is_domainadmin() ) {
        $params->{'domain_id'} = $self->user->get_domain_id();
    }

    my @domains = $self->{'Domain'}->list($params);
    my @types   = keys %{ $self->{'Record'}->valid_types() };

    my %params = (
        'title'         => $self->{lh}->maketext('Add Record'),
        'domains'       => \@domains,
        'current'       => 'records',
        'types'         => \@types,
        'large_content' => $large_content,
    );

    return $self->tt_process( 'vdnsadm/record/create.tpl', \%params );
}

sub show_add_record {
    my $self = shift;

    # Get CGI Query object
    my $q = $self->query();

    my $domain_id = $q->param('domain_id');

    # set params
    my $params = { 'domain_id' => $domain_id, };
    foreach my $field ( @{ $self->{'Record'}->fields() } ) {
        next if $field eq 'id';
        if ( defined( $q->param($field) ) ) {
            $params->{$field} = $q->param($field);
        }
    }

    if ( $self->{'Record'}->create($params) ) {
        $self->log( 'Added Record for Domain #' . $domain_id );
    }
    else {
        $self->log( 'Failed to add Record for Domain #' . $domain_id, 'error' );
        $self->add_message( 'error', 'Database Error!' );
    }

    $self->redirect( $self->{base_url} . '?rm=domain&domain_id=' . $domain_id );
    return;
}

sub show_remove_record {
    my $self = shift;

    # Get CGI Query object
    my $q = $self->query();

    my $record_id = $q->param('record_id');
    my $domain_id = $self->{'Record'}->get_domain_id($record_id);

    if ( $self->{'Record'}->delete($record_id) ) {
        $self->log( 'Deleted Record #' . $record_id );
    }
    else {
        $self->log( 'Failed to delete Record #' . $record_id );
        $self->add_message( 'error', 'Database Error!' );
    }

    $self->redirect( $self->{base_url} . '?rm=domain&domain_id=' . $domain_id );
    return;
}

sub show_edit_record {
    my $self = shift;

    if ( !$self->user->is_admin() ) {
        my $msg = "You are not authorized to access this page.";
        $self->log( $msg . ". User: " . $self->authen->username );
        $self->add_message( 'error', $self->{lh}->maketext($msg) );
        $self->redirect( $self->{base_url} . '?rm=welcome' );
        return;
    }

    # Get our database connection
    my $dbh = $self->dbh();

    # Get CGI Query object
    my $q = $self->query();

    my $large_content = $q->param('large') || 0;

    my $record_id   = $q->param('record_id');
    my $record_ref  = $self->{'Record'}->read($record_id);
    my $domain_id   = $record_ref->{'domain_id'};
    my $domain_name = $record_ref->{'domain'};
    my @types       = $self->{'Record'}->types();

    $record_ref->{'name'} =~ s/\.$domain_name$//;

    my %params = (
        'title'         => $self->{lh}->maketext('Edit Record'),
        'record_id'     => $record_id,
        'domain_name'   => $domain_name,
        'current'       => 'records',
        'types'         => \@types,
        'large_content' => $large_content,
    );

    foreach my $key ( keys %{$record_ref} ) {
        $params{$key} = $record_ref->{$key};
    }
    if ( length( $params{'content'} ) > 20 ) {
        $params{'large_content'} = 1;
    }

    return $self->tt_process( 'vdnsadm/record/edit.tpl', \%params );
}

sub show_update_record {
    my $self = shift;

    if ( !$self->user->is_admin() ) {
        my $msg = "You are not authorized to access this page.";
        $self->log( $msg . ". User: " . $self->authen->username );
        $self->add_message( 'error', $self->{lh}->maketext($msg) );
        $self->redirect( $self->{base_url} . '?rm=welcome' );
        return;
    }

    # Get CGI Query object
    my $q = $self->query();

    my $record_id = $q->param('record_id');

    # set params
    my $params = {};
    foreach my $field ( @{ $self->{'Record'}->fields() } ) {
        next if $field eq 'id';
        $params->{$field} = $q->param($field) if defined( $q->param($field) );
    }

    if ( $self->{'Record'}->update( $record_id, $params ) ) {
        $self->log( 'Updated Record #' . $record_id );
    }
    else {
        $self->log( 'Failed to update Record #' . $record_id );
        $self->add_message( 'error', 'Database Error!' );
    }
    my $domain_id = $self->{'Record'}->get_domain_id($record_id);

    $self->redirect( $self->{base_url} . '?rm=domain&domain_id=' . $domain_id );
    return;
}

#
# Log
#

sub show_log {
    my $self = shift;

    if ( !$self->user->is_siteadmin() ) {
        my $msg = "You are not authorized to access this page.";
        $self->log( $msg . ". User: " . $self->authen->username );
        $self->add_message( 'error', $self->{lh}->maketext($msg) );
        $self->redirect( $self->{base_url} . '?rm=welcome' );
        return;
    }

    # Get CGI Query object
    my $q = $self->query();

    # Get our database connection
    my $dbh = $self->dbh();

    my $search = $q->param('search') || '';
    my $page   = $q->param('page')   || 1;

    # TT Params
    my %params = (
        'title'   => $self->{lh}->maketext('VDnsAdm Log'),
        'current' => 'log',
        'search'  => $search,
    );

    my @args  = ();
    my $query = "SELECT ts,msg FROM log ";
    if ($search) {
        $query .= "WHERE msg LIKE ? ";
        $search =~ s/%//g;
        my $search_arg = "%" . $search . "%";
        push( @args, $search_arg );
    }
    $query .= "ORDER BY ts DESC";

    # Get the actual data
    my $sth = $dbh->prepare($query);
    if ( !$sth ) {
        $self->add_message( 'error', 'Database Error!' );
        $self->log( 'Could not prepare Query: ' . $query . ', Error: ' . DBI->errstr, 'warning', );
        return $self->tt_process( 'vwebadm/log.tpl', \%params );
    }
    if ( !$sth->execute(@args) ) {
        $self->add_message( 'error', 'Database Error!' );
        $self->log( 'Could not execute Query: ' . $query . ', Args: ' . join( "-", @args ) . ', Error: ' . $sth->errstr, 'warning', );
        return $self->tt_process( 'vwebadm/log.tpl', \%params );
    }

    my @log = ();
    while ( my ( $ts, $msg ) = $sth->fetchrow_array() ) {
        push( @log, { ts => $ts, msg => $msg, } );
    }
    $sth->finish();
    $params{'log'} = \@log;

    return $self->tt_process( 'vwebadm/log.tpl', \%params );
}

#
# Admins
#

sub show_users {
    my $self = shift;

    if ( !$self->user->is_siteadmin() ) {
        my $msg = "You are not authorized to access this page.";
        $self->log( $msg . ". User: " . $self->authen->username );
        $self->add_message( 'error', $self->{lh}->maketext($msg) );
        $self->redirect( $self->{base_url} . '?rm=welcome' );
        return;
    }

    # Get our database connection
    my $dbh = $self->dbh();

    # Get CGI Query object
    my $q = $self->query();

    my $page   = $q->param('page') || 1;
    my $search = $q->param('search');
    my %params = (
        'Search'  => $search,
        'IsAdmin' => 1,
    );

    my @users = $self->{'User'}->list( \%params );

    %params = (
        'title'   => $self->{lh}->maketext('VDnsAdm Admins'),
        'current' => 'user',
        'users'   => \@users,
        'search'  => $search,
    );

    return $self->tt_process( 'vdnsadm/user/list.tpl', \%params );
}

sub show_create_user {
    my $self = shift;

    if ( !$self->user->is_siteadmin() ) {
        my $msg = "You are not authorized to access this page.";
        $self->log( $msg . ". User: " . $self->authen->username );
        $self->add_message( 'error', $self->{lh}->maketext($msg) );
        $self->redirect( $self->{base_url} . '?rm=welcome' );
        return;
    }

    # Get CGI Query object
    my $q = $self->query();

    my $params = {};

    my @users = $self->{'User'}->list($params);

    my %params = (
        'title'   => $self->{lh}->maketext('Add User'),
        'users'   => \@users,
        'current' => 'records',
    );

    return $self->tt_process( 'vdnsadm/user/create.tpl', \%params );
}

sub show_add_user {
    my $self = shift;

    # Get CGI Query object
    my $q = $self->query();

    my $domain_id = $q->param('domain_id');

    # set params
    my $params = {};
    foreach my $field ( @{ $self->{'User'}->fields() } ) {
        next if $field eq 'id';
        if ( defined( $q->param($field) ) ) {
            $params->{$field} = $q->param($field);
        }
    }

    if ( $self->{'User'}->create( $domain_id, $params ) ) {
        $self->log( 'Added User for Domain #' . $domain_id );
    }
    else {
        $self->log( 'Failed to add User for Domain #' . $domain_id, 'error' );
        $self->add_message( 'error', 'Database Error!' );
    }

    $self->redirect( $self->{base_url} . '?rm=users' );
    return;
}

sub show_remove_user {
    my $self = shift;

    # Get CGI Query object
    my $q = $self->query();

    my $user_id = $q->param('user_id');

    if ( $self->{'User'}->delete($user_id) ) {
        $self->log( 'Deleted User #' . $user_id );
    }
    else {
        $self->log( 'Failed to delete User #' . $user_id );
        $self->add_message( 'error', 'Database Error!' );
    }

    $self->redirect( $self->{base_url} . '?rm=users' );
    return;
}

sub show_edit_user {
    my $self = shift;

    if ( !$self->user->is_admin() ) {
        my $msg = "You are not authorized to access this page.";
        $self->log( $msg . ". User: " . $self->authen->username );
        $self->add_message( 'error', $self->{lh}->maketext($msg) );
        $self->redirect( $self->{base_url} . '?rm=welcome' );
        return;
    }

    # Get our database connection
    my $dbh = $self->dbh();

    # Get CGI Query object
    my $q = $self->query();

    my $large_content = $q->param('large') || 0;

    my $user_id = $q->param('user_id');

    # Authorization
    if ( !$self->user->is_siteadmin() ) {
        $user_id = $self->id();
    }

    my $record_ref  = $self->{'User'}->read($user_id);
    my $domain_id   = $record_ref->{'domain_id'};
    my $domain_name = $record_ref->{'domain'};

    my %params = (
        'title'       => $self->{lh}->maketext('Edit User'),
        'user_id'     => $user_id,
        'domain_name' => $domain_name,
        'current'     => 'admins',
    );
    foreach my $key ( keys %{$record_ref} ) {
        $params{$key} = $record_ref->{$key};
    }

    return $self->tt_process( 'vdnsadm/user/edit.tpl', \%params );
}

sub show_update_user {
    my $self = shift;

    # Get CGI Query object
    my $q = $self->query();

    my $user_id = $q->param('user_id');

    # set params
    my $params = {};
    foreach my $field ( @{ $self->{'User'}->fields() } ) {
        next if $field eq 'id';
        $params->{$field} = $q->param($field) if defined( $q->param($field) );
    }

    if ( $self->{'User'}->update( $user_id, $params ) ) {
        $self->log( 'Updated User #' . $user_id );
    }
    else {
        $self->log( 'Failed to update User #' . $user_id );
        $self->add_message( 'error', 'Database Error!' );
    }

    $self->redirect( $self->{base_url} . '?rm=users' );
    return;
}

# Groups
sub show_groups {
    my $self = shift;

    if ( !$self->user->is_siteadmin() ) {
        my $msg = "You are not authorized to access this page.";
        $self->log( $msg . ". User: " . $self->authen->username );
        $self->add_message( 'error', $self->{lh}->maketext($msg) );
        $self->redirect( $self->{base_url} . '?rm=welcome' );
        return;
    }

    # Get our database connection
    my $dbh = $self->dbh();

    # Get CGI Query object
    my $q = $self->query();

    my $page   = $q->param('page') || 1;
    my $search = $q->param('search');
    my %params = ( 'Search' => $search, );

    my @groups = $self->{'Group'}->list( \%params );

    %params = (
        'title'   => $self->{lh}->maketext('VDnsAdm Groups'),
        'current' => 'groups',
        'groups'  => \@groups,
        'search'  => $search,
    );

    return $self->tt_process( 'vdnsadm/group/list.tpl', \%params );
}

sub show_create_group {
    my $self = shift;

    if ( !$self->user->is_siteadmin() ) {
        my $msg = "You are not authorized to access this page.";
        $self->log( $msg . ". User: " . $self->authen->username );
        $self->add_message( 'error', $self->{lh}->maketext($msg) );
        $self->redirect( $self->{base_url} . '?rm=welcome' );
        return;
    }

    # Get CGI Query object
    my $q = $self->query();

    my $params = {};

    my %params = (
        'title'   => $self->{lh}->maketext('Add Group'),
        'current' => 'records',
    );

    return $self->tt_process( 'vdnsadm/group/create.tpl', \%params );
}

sub show_add_group {
    my $self = shift;

    # Get CGI Query object
    my $q = $self->query();

    # set params
    my $params = {};
    foreach my $field ( @{ $self->{'Group'}->fields() } ) {
        next if $field eq 'id';
        if ( defined( $q->param($field) ) ) {
            $params->{$field} = $q->param($field);
        }
    }

    if ( $self->{'Group'}->create($params) ) {
        $self->log('Added Group');
    }
    else {
        $self->log( 'Failed to add Group', 'error' );
        $self->add_message( 'error', 'Database Error!' );
    }

    $self->redirect( $self->{base_url} . '?rm=groups' );
    return;
}

sub show_remove_group {
    my $self = shift;

    # Get CGI Query object
    my $q = $self->query();

    my $group_id = $q->param('group_id');

    if ( $self->{'Group'}->delete($group_id) ) {
        $self->log( 'Deleted Group #' . $group_id );
    }
    else {
        $self->log( 'Failed to delete Group #' . $group_id );
        $self->add_message( 'error', 'Database Error!' );
    }

    $self->redirect( $self->{base_url} . '?rm=groups' );
    return;
}

sub show_edit_group {
    my $self = shift;

    if ( !$self->user->is_siteadmin() ) {
        my $msg = "You are not authorized to access this page.";
        $self->log( $msg . ". User: " . $self->authen->username );
        $self->add_message( 'error', $self->{lh}->maketext($msg) );
        $self->redirect( $self->{base_url} . '?rm=welcome' );
        return;
    }

    # Get our database connection
    my $dbh = $self->dbh();

    # Get CGI Query object
    my $q = $self->query();

    my $group_id = $q->param('group_id');

    my $record_ref = $self->{'Group'}->read($group_id);

    my %params = (
        'title'    => $self->{lh}->maketext('Edit Group'),
        'group_id' => $group_id,
        'current'  => 'groups',
    );
    foreach my $key ( keys %{$record_ref} ) {
        $params{$key} = $record_ref->{$key};
    }

    return $self->tt_process( 'vdnsadm/group/edit.tpl', \%params );
}

sub show_update_group {
    my $self = shift;

    # Get CGI Query object
    my $q = $self->query();

    my $group_id = $q->param('group_id');

    # set params
    my $params = {};
    foreach my $field ( @{ $self->{'Group'}->fields() } ) {
        next if $field eq 'id';
        $params->{$field} = $q->param($field) if defined( $q->param($field) );
    }

    if ( $self->{'Group'}->update( $group_id, $params ) ) {
        $self->log( 'Updated Group #' . $group_id );
    }
    else {
        $self->log( 'Failed to update Group #' . $group_id );
        $self->add_message( 'error', 'Database Error!' );
    }

    $self->redirect( $self->{base_url} . '?rm=groups' );
    return;
}

# Templates
sub show_templates {
    my $self = shift;

    if ( !$self->user->is_siteadmin() ) {
        my $msg = "You are not authorized to access this page.";
        $self->log( $msg . ". User: " . $self->authen->username );
        $self->add_message( 'error', $self->{lh}->maketext($msg) );
        $self->redirect( $self->{base_url} . '?rm=welcome' );
        return;
    }

    # Get our database connection
    my $dbh = $self->dbh();

    # Get CGI Query object
    my $q = $self->query();

    my $page   = $q->param('page') || 1;
    my $search = $q->param('search');
    my %params = ( 'Search' => $search, );

    my @templates = $self->{'Template'}->list( \%params );

    %params = (
        'title'     => $self->{lh}->maketext('VDnsAdm Templates'),
        'current'   => 'templates',
        'templates' => \@templates,
        'search'    => $search,
    );

    return $self->tt_process( 'vdnsadm/template/list.tpl', \%params );
}

sub show_template {
    my $self = shift;

    if ( !$self->user->is_siteadmin() ) {
        my $msg = "You are not authorized to access this page.";
        $self->log( $msg . ". User: " . $self->authen->username );
        $self->add_message( 'error', $self->{lh}->maketext($msg) );
        $self->redirect( $self->{base_url} . '?rm=welcome' );
        return;
    }

    # Get our database connection
    my $dbh = $self->dbh();

    # Get CGI Query object
    my $q = $self->query();

    my $template_id = $q->param('template_id') || undef;

    if ( !$template_id || $template_id !~ m/^\d+$/ ) {
        my $msg = "Invalid Template-ID.";
        $self->log( $msg . ". User: " . $self->authen->username );
        $self->add_message( 'error', $msg );
        $self->redirect( $self->{base_url} . '?rm=welcome' );
        return;
    }

    my $params = {};

    my $sql = undef;
    my $sth = undef;

    # Get Domain name
    my $template_ref  = $self->{'Template'}->read($template_id);
    my $template_name = $template_ref->{'name'};

    # Get Records
    my @records   = $self->{'TemplateRecord'}->list( { 'tpl_id' => $template_id, 'NotType' => 'SOA', }, );
    my @types     = $self->{'TemplateRecord'}->types();
    my @templates = $self->{'Template'}->list($params);

    my %params = (
        'title'         => $self->{lh}->maketext( 'VDnsAdm Template: [_1]', $template_name ),
        'current'       => 'templates',
        'template_name' => $template_name,
        'records'       => \@records,
        'types'         => \@types,
        'templates'     => \@templates,
        'template_id'   => $template_id,
    );

    return $self->tt_process( 'vdnsadm/template/show.tpl', \%params );
}

sub show_create_template {
    my $self = shift;

    if ( !$self->user->is_siteadmin() ) {
        my $msg = "You are not authorized to access this page.";
        $self->log( $msg . ". User: " . $self->authen->username );
        $self->add_message( 'error', $self->{lh}->maketext($msg) );
        $self->redirect( $self->{base_url} . '?rm=welcome' );
        return;
    }

    # Get CGI Query object
    my $q = $self->query();

    my $params = {};

    my %params = (
        'title'   => $self->{lh}->maketext('Add Template'),
        'current' => 'templates',
    );

    return $self->tt_process( 'vdnsadm/template/create.tpl', \%params );
}

sub show_add_template {
    my $self = shift;

    # Get CGI Query object
    my $q = $self->query();

    # set params
    my $params = {};
    foreach my $field ( @{ $self->{'User'}->fields() } ) {
        next if $field eq 'id';
        if ( defined( $q->param($field) ) ) {
            $params->{$field} = $q->param($field);
        }
    }

    if ( $self->{'Template'}->create($params) ) {
        $self->log('Added Template');
    }
    else {
        $self->log( 'Failed to add Template', 'error' );
        $self->add_message( 'error', 'Database Error!' );
    }

    $self->redirect( $self->{base_url} . '?rm=templates' );
    return;
}

sub show_remove_template {
    my $self = shift;

    # Get CGI Query object
    my $q = $self->query();

    my $template_id = $q->param('template_id');

    if ( $self->{'Template'}->delete($template_id) ) {
        $self->log( 'Deleted Template #' . $template_id );
    }
    else {
        $self->log( 'Failed to delete Template #' . $template_id );
        $self->add_message( 'error', 'Database Error!' );
    }

    $self->redirect( $self->{base_url} . '?rm=templates' );
    return;
}

sub show_edit_template {
    my $self = shift;

    if ( !$self->user->is_siteadmin() ) {
        my $msg = "You are not authorized to access this page.";
        $self->log( $msg . ". User: " . $self->authen->username );
        $self->add_message( 'error', $self->{lh}->maketext($msg) );
        $self->redirect( $self->{base_url} . '?rm=welcome' );
        return;
    }

    # Get our database connection
    my $dbh = $self->dbh();

    # Get CGI Query object
    my $q = $self->query();

    my $template_id = $q->param('template_id');

    my $record_ref = $self->{'Template'}->read($template_id);

    my %params = (
        'title'       => $self->{lh}->maketext('Edit Template'),
        'template_id' => $template_id,
        'current'     => 'templates',
    );
    foreach my $key ( keys %{$record_ref} ) {
        $params{$key} = $record_ref->{$key};
    }

    return $self->tt_process( 'vdnsadm/template/edit.tpl', \%params );
}

sub show_update_template {
    my $self = shift;

    # Get CGI Query object
    my $q = $self->query();

    my $template_id = $q->param('template_id');

    # set params
    my $params = {};
    foreach my $field ( @{ $self->{'Template'}->fields() } ) {
        next if $field eq 'id';
        $params->{$field} = $q->param($field) if defined( $q->param($field) );
    }

    if ( $self->{'Template'}->update( $template_id, $params ) ) {
        $self->log( 'Updated Template #' . $template_id );
    }
    else {
        $self->log( 'Failed to update Template #' . $template_id );
        $self->add_message( 'error', 'Database Error!' );
    }

    $self->redirect( $self->{base_url} . '?rm=templates' );
    return;
}

# TemplateRecords
sub show_template_records {
    my $self = shift;

    if ( !$self->user->is_siteadmin() ) {
        my $msg = "You are not authorized to access this page.";
        $self->log( $msg . ". User: " . $self->authen->username );
        $self->add_message( 'error', $self->{lh}->maketext($msg) );
        $self->redirect( $self->{base_url} . '?rm=welcome' );
        return;
    }

    # Get our database connection
    my $dbh = $self->dbh();

    # Get CGI Query object
    my $q = $self->query();

    my $page   = $q->param('page') || 1;
    my $search = $q->param('search');
    my %params = ( 'Search' => $search, );

    my @recs = $self->{'TemplateRecord'}->list( \%params );

    %params = (
        'title'   => $self->{lh}->maketext('VDnsAdm Template Records'),
        'current' => 'templates',
        'records' => \@recs,
        'search'  => $search,
    );

    return $self->tt_process( 'vdnsadm/template_record/list.tpl', \%params );
}

sub show_create_template_record {
    my $self = shift;

    if ( !$self->user->is_siteadmin() ) {
        my $msg = "You are not authorized to access this page.";
        $self->log( $msg . ". User: " . $self->authen->username );
        $self->add_message( 'error', $self->{lh}->maketext($msg) );
        $self->redirect( $self->{base_url} . '?rm=welcome' );
        return;
    }

    # Get CGI Query object
    my $q = $self->query();

    my $params = {};

    my %params = (
        'title'   => $self->{lh}->maketext('Add Template Record'),
        'current' => 'templates',
    );

    return $self->tt_process( 'vdnsadm/template_record/create.tpl', \%params );
}

sub show_add_template_record {
    my $self = shift;

    # Get CGI Query object
    my $q = $self->query();

    # set params
    my $params = {};
    foreach my $field ( @{ $self->{'TemplateRecord'}->fields() } ) {
        next if $field eq 'id';
        if ( defined( $q->param($field) ) ) {
            $params->{$field} = $q->param($field);
        }
    }

    my $tpl_id = $params->{'tpl_id'};

    if ( $self->{'TemplateRecord'}->create($params) ) {
        $self->log( 'Added Record for Template #' . $tpl_id );
    }
    else {
        $self->log( 'Failed to add Record for Template #' . $tpl_id, 'error' );
        $self->add_message( 'error', 'Database Error!' );
    }

    $self->redirect( $self->{base_url} . '?rm=template&template_id=' . $tpl_id );
    return;
}

sub show_remove_template_record {
    my $self = shift;

    # Get CGI Query object
    my $q = $self->query();

    my $record_id = $q->param('record_id');

    my $tpl_id = $self->{'TemplateRecord'}->get_tpl_id($record_id);

    if ( $self->{'TemplateRecord'}->delete($record_id) ) {
        $self->log( 'Deleted Template Record #' . $record_id );
    }
    else {
        $self->log( 'Failed to delete Record #' . $record_id );
        $self->add_message( 'error', 'Database Error!' );
    }

    $self->redirect( $self->{base_url} . '?rm=template&template_id=' . $tpl_id );
    return;
}

sub show_edit_template_record {
    my $self = shift;

    if ( !$self->user->is_siteadmin() ) {
        my $msg = "You are not authorized to access this page.";
        $self->log( $msg . ". User: " . $self->authen->username );
        $self->add_message( 'error', $self->{lh}->maketext($msg) );
        $self->redirect( $self->{base_url} . '?rm=welcome' );
        return;
    }

    # Get our database connection
    my $dbh = $self->dbh();

    # Get CGI Query object
    my $q = $self->query();

    my $large_content = $q->param('large') || 0;

    my $record_id = $q->param('record_id');

    my $record_ref = $self->{'TemplateRecord'}->read($record_id);

    my %params = (
        'title'     => $self->{lh}->maketext('Edit Template Record'),
        'record_id' => $record_id,
        'current'   => 'templates',
    );
    foreach my $key ( keys %{$record_ref} ) {
        $params{$key} = $record_ref->{$key};
    }

    return $self->tt_process( 'vdnsadm/template_record/edit.tpl', \%params );
}

sub show_update_template_record {
    my $self = shift;

    # Get CGI Query object
    my $q = $self->query();

    my $record_id = $q->param('record_id');

    # set params
    my $params = {};
    foreach my $field ( @{ $self->{'TemplateRecord'}->fields() } ) {
        next if $field eq 'id';
        $params->{$field} = $q->param($field) if defined( $q->param($field) );
    }

    if ( $self->{'TemplateRecord'}->update( $record_id, $params ) ) {
        $self->log( 'Updated Template Record #' . $record_id );
    }
    else {
        $self->log( 'Failed to update Template Record #' . $record_id );
        $self->add_message( 'error', 'Database Error!' );
    }

    $self->redirect( $self->{base_url} . '?rm=users' );
    return;
}

1;

__END__

=head1 NAME

VDnsAdm::Controller::Frontend - Frontend for VDnsAdm

=cut