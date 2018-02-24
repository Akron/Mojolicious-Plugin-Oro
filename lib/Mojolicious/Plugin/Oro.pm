package Mojolicious::Plugin::Oro;
use Mojo::Base 'Mojolicious::Plugin';
use File::Spec;
use DBIx::Oro;

our $VERSION = '0.07';

# Todo:
# - return Mojo-Collections instead of Array-refs on select etc. Possible?

# Register Plugin
sub register {
  my ($plugin, $mojo, $param) = @_;

  # Load parameter from Config file
  if (my $config_param = $mojo->config('Oro')) {
    $param = { %$param, %$config_param };
  };

  # Hash of database handles
  my ($databases, $db_init);

  # No databases attached
  unless ($mojo->can('oro_handles')) {
    $databases = {};
    $mojo->attr(
      oro_handles => sub {
	return $databases;
      });
  }
  else {
    $databases = $mojo->oro_handles;
  };

  # Add oro_init command
  push @{$mojo->commands->namespaces}, __PACKAGE__;

  # Initialize database
  my $_init_database = sub {

    $db_init = 1;

    # Loop through all databases
    foreach my $name (keys %$param) {
      my $db = $param->{$name};

      # Already exists
      if (exists $databases->{$name}) {
	$mojo->log->warn("Multiple attempts to establish database '$name'");
	next;
      };

      # Make path portable
      # (Especially for mounted apps)
      if ($db->{file} &&
	    index($db->{file}, ':') != 0 &&
	      !File::Spec->file_name_is_absolute($db->{file})) {

	# Specify local path depending on app home
	$db->{file} = File::Spec->catdir($mojo->home, $db->{file});
      };

      # Remove init advice
      my $init = delete $db->{init};

      # Get Database handle
      my $oro = DBIx::Oro->new(
	%$db,
	on_connect => sub {
	  my $oro = shift;
	  $mojo->log->info( 'Connect ' . $name . ' from ' . $$ );

	  # Emit on_oro_connect hook
	  $mojo->plugins->emit_hook(
	    'on_' . ($name ne 'default' ? $name . '_' : '') . 'oro_connect' =>
	      $oro, $mojo
	    );
	}
      );

      # Use init advice per hook
      if ($init) {
	$mojo->hook(
	  'on_' . ($name ne 'default' ? $name . '_' : '') . 'oro_init' =>
	    $init
	  )
      };

      # Database newly created
      if ($oro->can('created') && $oro->created) {

	# Emit on_oro_init hook
	$mojo->plugins->emit_hook(
	  'on_' . ($name ne 'default' ? $name . '_' : '') . 'oro_init' => (
	    $oro, $mojo
	  )
	);

	# Initialization log message
	$mojo->log->info(qq{Initialized Oro-DB "$name"});
      };

      # No succesful creation
      unless ($oro) {
	$mojo->log->warn(qq{Unable to create database handle "$name"});
      };

      # Store database handle
      $databases->{$name} = $oro;
    };
  };

  # Init databases
  Mojo::IOLoop->timer(
    0 => $_init_database
  );

  # Add helper
  $mojo->helper(
    oro => sub {
      my ($c, $name, $table) = @_;
      $name //= 'default';

      unless ($db_init) {
	$_init_database->();
      }
      # Mojo::IOLoop->next_tick unless Mojo::IOLoop->is_running;

      my $oro = $databases->{$name};

      # Database unknown
      $mojo->log->warn("Unknown database '$name'") unless $oro;

      # Return database handle
      return $oro unless $table;

      # Return table handle
      return $oro->table($table);
   });
};


1;


__END__

=pod

=head1 NAME

Mojolicious::Plugin::Oro - DBIx::Oro driver plugin for Mojolicious

=head1 SYNOPSIS

  $app->plugin(Oro => {
    Books => {
      file => 'Database/Books.sqlite'
    }
  );

  # Or in your config file
  {
    Oro => {
      default => { file => ':memory:' }
    }
  }

  $c->oro('Books')->insert(Content => { title => 'Misery' });
  print $c->oro(Books => 'Content')->count;

=head1 DESCRIPTION

L<Mojolicious::Plugin::Oro> is a simple plugin to work with
L<DBIx::Oro|https://github.com/Akron/DBIx-Oro>.

B<Warning>: It is recommended to use L<Mojo::SQLite> instead of this module!

=head1 HELPERS

=head2 C<oro>

  # In Controllers:
  $c->oro('Books')->insert(Content => { title => 'Misery' });
  print $c->oro(Books => 'Content')->count;

Returns an Oro database handle if registered.
Accepts the name of the registered database and optionally
a table name.
If no database handle name is given, a database handle name
C<default> is assumed.


=head1 METHODS

L<Mojolicious::Plugin::Oro> inherits all methods from
L<Mojolicious::Plugin> and implements the following new ones.

=head2 C<register>

  # Mojolicious
  $app->plugin('Oro' => {
    Books => {
      file => 'Database/Books.sqlite',
      init => sub {
        my $oro = shift;
        $oro->txn(sub{
          $oro->do('CREATE TABLE Content (
                       id      INTEGER PRIMARY KEY,
                       title   TEXT,
                       content TEXT
                    )') or return -1;
          }) or return;
      }
    }}
  );

  # Mojolicious::Lite
  plugin 'Oro' => {
    Books => { file => 'Database/Books.sqlite' }
  };

Called when registering the plugin.
On creation, the plugin accepts a hash of database names
associated with a L<DBIx::Oro|https://github.com/Akron/DBIx-Oro> object.
All parameters can be set either on registration or
as part of the configuration file with the key C<Oro>.

The database handles have to be unique, i.e.
you can't have multiple different C<default> databases in mounted
applications using L<Mojolicious::Plugin::Mount>.

=head1 HOOKS

=head2 C<on_DBNAME_oro_init>

  $app->plugin(Oro => {
    Books => {
      file => 'Database/Books.sqlite';
    }
  });

  $app->hook(
    on_Books_oro_init => sub {
      my $oro = shift;
      $oro->init_db;
    });

This hook is run when an oro database of the given name
is initialized. In case of the default database,
the handle of the hook is C<on_oro_init>.
This hook will be automatically released in case an
SQLite database was created.


=head2 C<on_DBNAME_oro_connect>

  $app->plugin(Oro => {
    Books => {
      file => 'Database/Books.sqlite';
    }
  });

  $app->hook(
    on_Books_oro_connect => sub {
      my $oro = shift;
      $app->log->debug('Database ' . $oro->file . ' is connected!');
    });


This hook is run when an oro database of the given name
is connected. In case of the default database,
the handle of the hook is C<on_oro_connect>.


=head1 COMMANDS

=head2 C<oro_init>

  perl app.pl oro_init

As the hook C<on_DBNAME_oro_init> is only automatically released
in case of newly created SQLite instances, the hook can be forced
by manually initializing the databases using the
L<Mojolicious::Plugin::Oro::oro_init> command.


=head1 DEPENDENCIES

L<Mojolicious>,
L<DBIx::Oro|https://github.com/Akron/DBIx-Oro>.


=head1 AVAILABILITY

  https://github.com/Akron/Mojolicious-Plugin-Oro


=head1 COPYRIGHT AND LICENSE

Copyright (C) 2012-2015, Nils Diewald.

This program is free software, you can redistribute it
and/or modify it under the same terms as Perl.

=cut
