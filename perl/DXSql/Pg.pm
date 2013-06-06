#
# Module for SQLite DXSql variants
#
# Stuff like table creates and (later) alters
#
# Copyright (c) 2005 Dirk Koopman G1TLH
# Modifications made for Pg, Copyright (c) 2012 Wijnand Modderman-Lenstra PD0MZ
#

package DXSql::Pg;

use DXDebug;

use vars qw(@ISA);
@ISA = qw{DXSql};

sub show_tables
{
	my $self = shift;
	#my $s = q(show tables);
    my $s = q(SELECT table_name FROM information_schema.tables WHERE table_schema = 'public';);
	my $sth = $self->prepare($s);
	$sth->execute;
	my @out;
	while (my @t = $sth->fetchrow_array) {
		push @out, @t;
	}
	$sth->finish;
	return @out;
}

sub has_ipaddr
{
	my $self = shift;
	my $s = q(SELECT column_name FROM information_schema.columns WHERE table_name = 'spot');
	my $sth = $self->prepare($s);
	$sth->execute;
	while (my @t = $sth->fetchrow_array) {
		if ($t[0] eq 'ipaddr') {
			$sth->finish;
			return 1;
		}
	}
	$sth->finish;
	return undef;
}

sub add_ipaddr
{
	my $self = shift;
	my $s = q(alter table spot add column ipaddr varchar(40));
	$self->do($s);
}

sub spot_create_table
{
	my $self = shift;
    my $s;
    $s = q{create sequence spot_rowid_seq};
    $self->do($s);
	$s = q{create table spot (
rowid sequence primary key ,
freq real not null,
spotcall varchar(14) not null,
time int not null,
comment varchar(255),
spotter varchar(14) not null,
spotdxcc smallint,
spotterdxcc smallint,
origin varchar(14),
spotitu tinyint,
spotcq tinyint,
spotteritu tinyint,
spottercq tinyint,
spotstate char(2),
spotterstate char(2),
ipaddr varchar(40)
)};
	$self->do($s);
    $s = q{alter table spot alter column rowid set default nextval('spot_rowid_seq');};
    $self->do($s);
}

sub spot_add_indexes
{
	my $self = shift;
	#dbg('adding spot index ix1');
	#$self->do('create index spot_ix1 on spot(time desc)');
	#dbg('adding spot index ix2');
	#$self->do('create index spot_ix2 on spot(spotcall asc)');
}

sub spot_insert
{
	my $self = shift;
	my $spot = shift;
	my $sth = shift;
	
	if ($sth) {
		push @$spot, undef while  @$spot < 15;
		pop @$spot while @$spot > 15;
		eval {$sth->execute(undef, @$spot)};
	} else {
		my $s = "insert into spot values(NEXTVAL('spot_rowid_seq'),";
		$s .= sprintf("%.1f,", $spot->[0]);
		$s .= $self->quote($spot->[1]) . "," ;
		$s .= $spot->[2] . ',';
		$s .= (length $spot->[3] ? $self->quote($spot->[3]) : 'NULL') . ',';
		$s .= $self->quote($spot->[4]) . ',';
		$s .= $spot->[5] . ',';
		$s .= $spot->[6] . ',';
		$s .= (length $spot->[7] ? $self->quote($spot->[7]) : 'NULL') . ',';
		$s .= $spot->[8] . ',';
		$s .= $spot->[9] . ',';
		$s .= $spot->[10] . ',';
		$s .= $spot->[11] . ',';
		$s .= (length $spot->[12] ? $self->quote($spot->[12]) : 'NULL') . ',';
		$s .= (length $spot->[13] ? $self->quote($spot->[13]) : 'NULL') . ',';
		$s .= (length $spot->[14] ? $self->quote($spot->[14]) : 'NULL') . ')';
		eval {$self->do($s)};
	}
}



1;  
