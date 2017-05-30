# Copyright (c) 2001-2003 Gregory M. Kurtzer
#
# Copyright (c) 2003-2011, The Regents of the University of California,
# through Lawrence Berkeley National Laboratory (subject to receipt of any
# required approvals from the U.S. Dept. of Energy).  All rights reserved.
#
# $Id$
#

package Warewulf::DataStore::SQL::SQLite;

use Warewulf::Config;
use Warewulf::Logger;
use Warewulf::DSO;
use Warewulf::Object;
use Warewulf::ObjectSet;
use Warewulf::EventHandler;
use DBI;

# We subclass the SQL base class:
use parent 'Warewulf::DataStore::SQL::BaseClass';


my $sqlite_db_schema = <<'END_OF_SQL';

CREATE TABLE meta (
    id              INTEGER PRIMARY KEY NOT NULL,
    name            TEXT,
    value           TEXT
  );
CREATE INDEX meta_name_idx ON meta(name);
INSERT INTO meta (name, value) VALUES ('dbvers', '1');

CREATE TABLE datastore (
    id              INTEGER PRIMARY KEY NOT NULL,
    type            TEXT,
    timestamp       INTEGER NOT NULL DEFAULT 0,
    serialized      BLOB,
    data            BLOB
  );
CREATE INDEX datastore_type_idx ON datastore(type);
CREATE TRIGGER datastore_insert_timestamp
    AFTER INSERT ON datastore
    FOR EACH ROW BEGIN
        UPDATE datastore SET timestamp = strftime('%s', 'now') WHERE rowid = NEW.rowid;
    END;
CREATE TRIGGER datastore_update_timestamp
    AFTER UPDATE OF type,serialized,data ON datastore
    FOR EACH ROW BEGIN
        UPDATE datastore SET timestamp = strftime('%s', 'now') WHERE id = NEW.id;
    END;


CREATE TABLE lookup (
    id              INTEGER PRIMARY KEY NOT NULL,
    object_id       INTEGER NOT NULL,
    field           TEXT,
    value           TEXT,

    FOREIGN KEY(object_id) REFERENCES datastore(id) ON DELETE CASCADE
  );
CREATE INDEX lookup_object_id_idx ON lookup(object_id);
CREATE INDEX lookup_field_idx ON lookup(field);


CREATE TABLE binstore (
    id              INTEGER PRIMARY KEY NOT NULL,
    object_id       INTEGER NOT NULL,
    chunk           BLOB,

    FOREIGN KEY(object_id) REFERENCES datastore(id) ON DELETE CASCADE
  );
CREATE INDEX binstore_object_id_idx ON binstore(object_id);

END_OF_SQL


=head1 NAME

Warewulf::DataStore::SQL::SQLite - SQLite Database interface to Warewulf

=head1 SYNOPSIS

    use Warewulf::DataStore::SQL::SQLite;

=head1 DESCRIPTION

    This class should not be instantiated directly.  It is intended to be
    treated as an opaque implementation of the DB interface.

    This class creates a persistant singleton for the application runtime
    which will maintain a consistant database connection from the time that
    the object is constructed.

    Documentation for each function should be found in the top level
    Warewulf::DataStore documentation. Any implementation specific documentation
    can be found here.

=cut


sub
open_database_handle_impl()
{
    my ($self, $db_name, $db_server, $db_user, $db_pass) = @_;

    #
    # If the path $db_name does not exist, then we'll need to initialize
    # the database, too:
    #
    my $needsInit = ( ! -f $db_name );

    my $dbh = DBI->connect_cached("DBI:SQLite:dbname=$db_name", '', '');

    if ( $dbh ) {
        if ( ! $dbh->do('PRAGMA foreign_keys = ON') ) {
            &wprint('Failed to enable foreign key support on $db_name');
        } elsif ( $needsInit ) {
            my $saved_multi_stmt = $dbh->{'sqlite_allow_multiple_statements'};

            $dbh->{'sqlite_allow_multiple_statements'} = 1;
            if ( ! $dbh->do($sqlite_db_schema) ) {
                &eprint('Failed to create database schema in $db_name');
                $dbh->disconnect();
                $dbh = undef;
            }
        }
    }
    return $dbh;
}


sub
chunk_size()
{
    my $self = shift;

    return $self->{"DATABASE_CHUNK_SIZE"} if ( exists($self->{"DATABASE_CHUNK_SIZE"}) );

    # Default chunk size is 1 MB:
    return 1024 * 1024;
}


sub
get_objects_build_query_impl()
{
    my $self = shift;
    my ($type, $field, $paramsRef, @strings) = @_;

    my @query_opts;

    if ($type) {
        push(@query_opts, 'datastore.type = '. $self->{"DBH"}->quote($type));
    }
    if ($field) {
        if (uc($field) eq "ID" or uc($field) eq "_ID") {
            push(@query_opts, 'datastore.id IN ('. join(',', map { $self->{"DBH"}->quote($_) } @strings). ')');
            @strings = ();
        } else {
            push(@query_opts, '(lookup.field = '. $self->{"DBH"}->quote(uc($field)) .' OR lookup.field = '. $self->{"DBH"}->quote(uc('_'. $field)) .')');
        }
    }

    if (@strings) {
        my @in_opts;
        my @like_opts;
        my @regexp_opts;
        my @string_query;
        foreach my $s (@strings) {
            if ( $s =~ /^\/(.+)\/$/ ) {
                push(@regexp_opts, $1);
            } elsif ($s =~ /[\*\?]/) {
                $s =~ s/\*/\%/g;
                $s =~ s/\?/\_/g;
                push(@like_opts, 'lookup.value LIKE '. $self->{"DBH"}->quote($s));
            } else {
                push(@in_opts, $self->{"DBH"}->quote($s));
            }
        }
        if (@in_opts) {
            push(@string_query, 'lookup.value IN ('. join(',', @in_opts). ')');
        }
        if (@like_opts) {
            push(@string_query, join(" OR ", @like_opts));
        }
        if (@regexp_opts) {
            push(@string_query, 'lookup.value REGEXP '. $self->{"DBH"}->quote('^('. join('|', @regexp_opts) .'$)'));
        }

        if (@string_query) {
            push(@query_opts, '(' . join(' OR ', @string_query) . ')');
        }
    }

    my $sql_query = <<'END_OF_SQL';
        SELECT
            datastore.id AS id,
            datastore.type AS type,
            datastore.timestamp AS timestamp,
            datastore.serialized AS serialized
          FROM datastore
          LEFT JOIN lookup ON lookup.object_id = datastore.id
END_OF_SQL
    if (@query_opts) {
        $sql_query .= ' WHERE '. join(' AND ', @query_opts);
    }
    $sql_query .= ' GROUP BY datastore.id';

    return $sql_query;
}


sub
get_lookups_build_query_impl()
{
    my $self = shift;
    my ($type, $field, $paramsRef, @strings) = @_;
    my @query_opts;

    if ($type) {
        push(@query_opts, 'datastore.type = ?');
        push(@$paramsRef, $type);
    }
    if ($field) {
        push(@query_opts, 'lookup.field = ?');
        push(@$paramsRef, uc($field));
    }
    if (@strings) {
        my $optStr = ',?' x scalar(@strings);
        push(@query_opts, 'lookup.value IN (' . substr($optStr, 1) . ')');
        foreach my $s (@strings) {
            push(@$paramsRef, $s);
        }
    }
    push(@query_opts, "lookup.field != 'ID'");

    my $sql_query = <<'END_OF_SQL';
        SELECT
            lookup.value AS value
          FROM lookup
          LEFT JOIN datastore ON lookup.object_id = datastore.id
END_OF_SQL
    if (@query_opts) {
        $sql_query .= ' WHERE '. join(' AND ', @query_opts);
    }
    $sql_query .= ' GROUP BY lookup.value';

    return $sql_query;
}


sub
allocate_object_impl()
{
    my $self = shift;
    my ($type) = @_;

    if (!exists($self->{"STH_INSTYPE"})) {
        $self->{"STH_INSTYPE"} = $self->{"DBH"}->prepare("INSERT INTO datastore (type) VALUES (?)");
    }
    if ( $self->{"STH_INSTYPE"}->execute($type) ) {
        return $self->{"DBH"}->last_insert_id('', '', 'datastore', 'id');
    }
    return undef;
}


=back

=head1 SEE ALSO

Warewulf::ObjectSet Warewulf::DataStore

=head1 COPYRIGHT

Copyright (c) 2001-2003 Gregory M. Kurtzer

Copyright (c) 2003-2011, The Regents of the University of California,
through Lawrence Berkeley National Laboratory (subject to receipt of any
required approvals from the U.S. Dept. of Energy).  All rights reserved.

=cut


1;

