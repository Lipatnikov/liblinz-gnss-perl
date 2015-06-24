=head1 LINZ::GNSS::SinexFile

  Package to extract basic information from a SINEX file.

  This is currently not written as a general purpose SINEX file reader/writer.

  The current purpose is simply to read station coordinate/covariance information.
  All sorts of assumptions are made - essentially hoping this works with Bernese generated
  SINEX files from ADDNEQ...

=cut

use strict;


package LINZ::GNSS::SinexFile;

use LINZ::GNSS::Time qw/yearday_seconds/;
use LINZ::Geodetic::Ellipsoid;
use PerlIO::gzip;
use Carp;


=head2 $sf=LINZ::GNSS::SinexFile->new($filename, %options)

Open and scan a SINEX file

Options can include

=over

=item full_covariance

Obtain the full coordinate covariance matrix.

=back

=cut 

sub new
{
    my( $class, $filename, %options ) = @_;
    my $self=bless { filename=>$filename }, $class;
    $self->_scan(%options) if $filename ne '';
    return $self;
}

=head2 $stns=$sf->stations()

Returns a list of stations in the SINEX file.  May be called in a scalar or array context.
Note this only returns stations for which coordinates have been calculated in the solution.
It does not return the full coordinate covariance matrix - just the covariance for the 
each station X,Y,Z coordinates.

Each station is returned as a hash with keys

=over

=item code

The four character code of the station (the SINEX site code)

=item solnid

The solution id for the site - each site can have multiple soutions

=item epoch 

The mean epoch of the solution

=item prmoffset

The offset of the X parameter in the full coordinate covariance matrix

=item xyz

An array hash with the xyz coordinate

=item covar

An array hash of array hashes defining the 3x3 covariance matrix

=back

=cut 

sub stations
{
    my($self)=@_;
    my @codes=sort {$a->{code} cmp $b->{code}} values %{$self->{stations}};
    my @stations  = map {sort {$a->{solnid} cmp $b->{solnid}} values %$_} @codes;
    @stations = sort {_cmpstn($a) cmp _cmpstn($b)} @stations;
    return wantarray ? @stations : \@stations;
}

=head2 $stn=$sf->station($code,$solnid)

Returns an individual station from the file by its code.  The station is returned in the same
way as for the stations() function.  If the solnid is omitted then fails if there is more than
one.

=cut 

sub station
{
    my($self,$code,$solnid)=@_;
    croak("Invalid station $code requested from SINEX file\n") 
       if ! exists($self->{stations}->{$code});
    if( $solnid eq '' )
    {
        my @solns=keys(%{$self->{station}->{solnid}});
        croak("Requested station $code doesn't have a unique solution\n");
    }
    else
    {
        croak("Invalid solution id $solnid for station $code requested from SINEX file\n") 
       if ! exists($self->{stations}->{$code}->{$solnid});
    }
    return $self->{stations}->{$code}->{$solnid};
}

=head2 $covar=$sf->covar()

Returns the lower triangle of the coordinate covariance matrix for the stations returned by $sf->stations().
The station order is defined by $stn->{prmoffset}.
Only valid if the sinex file was loaded with the full_covariance option.

=cut

sub covar
{
    my($self)=@_;
    return $self->{xyzcovar};
}

=head2 $sf->stats()

Returns a hash containing the solution statistics.  The values contained are

=over

=item nobs

The number of observations

=item nprm

The number of parameters

=item ndof

The degrees of freedom

=item seu

The standard error of unit weight

=back

=cut

sub stats
{
    my($self)=@_;
    return $self->{stats};
}


sub _open
{
    my ($self)=@_;
    my $filename=$self->{filename};
    return if ! $filename;

    my $stats={};
    my $station={};

    my $mode="<";
    if( $filename =~ /\.gz$/ )
    {
        $mode="<:gzip";
    }
    open( my $sf, $mode, $filename ) || croak("Cannot open SINEX file $filename\n");
    return $sf;
}

sub _scan
{
    my($self,%options) = @_;
    my $sf=$self->_open();
    return if ! $sf;

    
    $self->{stats}={};
    $self->{solnprms}={};
    $self->{stations}={};

    my $header=<$sf>;
    croak($self->{filename}." is not a valid SINEX file\n") if $header !~ /^\%\=SNX\s(\d\.\d\d)\s+/;
    my $version=$1;

    my $blocks={
        'SOLUTION/STATISTICS'=>0,
        'SOLUTION/EPOCHS'=>0,
        'SOLUTION/ESTIMATE'=>0,
        'SOLUTION/MATRIX_ESTIMATE L COVA'=>exists $options{need_covariance} && ! $options{need_covariance},
    };
    while( my $block=$self->_findNextBlock($sf) )
    {
        $blocks->{$block}=1 if
            ($block eq 'SOLUTION/STATISTICS' && $self->_scanStats($sf)) ||
            ($block eq 'SOLUTION/EPOCHS' && $self->_scanEpochs($sf)) ||
            ($block eq 'SOLUTION/ESTIMATE' && $self->_scanSolutionEstimate($sf)) ||
            ($block eq 'SOLUTION/MATRIX_ESTIMATE L COVA' && $self->_scanCovar($sf,$options{full_covariance}));
    }

    foreach my $block (sort keys %$blocks)
    {
        if( ! $blocks->{$block} )
        {
            croak($self->{filename}." does not contain a $block block\n");
        }
    }

    close($sf);
}

sub _findNextBlock
{
    my($self,$sf)=@_;
    my $block;
    while( my $line=<$sf> )
    {
        next if $line !~ /^\+/;
        my $block=substr($line,1);
        $block=~ s/\s+$//;
        return $block;
    }
    return '';
}

sub _trim
{
    my($value)=@_;
    return '' if ! defined $value;
    $value=~s/\s+$//;
    $value=~s/^\s+//;
    return $value;
}

sub _scanStats
{
    my( $self, $sf ) = @_;
    my $stats={ nobs=>0, nprm=>0, dof=>0, seu=>1.0 };
    $self->{stats} = $stats;

    while( my $line=<$sf> )
    {
        my $ctl=substr($line,0,1);
        last if $ctl eq '-';
        if( $ctl eq '+' )
        {
            carp("Invalid SINEX file - SOLUTION/STATISTICS not terminated\n");
            last;
        }
        next if $ctl ne ' ';
        my $item=_trim(substr($line,1,30));
        my $value=_trim(substr($line,32,22));
        $stats->{nobs}=$value+0 if $item eq 'NUMBER OF OBSERVATIONS';
        $stats->{dof}=$value+0 if $item eq 'NUMBER OF DEGREES OF FREEDOM';
        $stats->{nprm}=$value+0 if $item eq 'NUMBER OF UNKNOWNS';
        $stats->{seu}=sqrt($value+0) if $item eq 'VARIANCE FACTOR';
    }
    return 1;
}

# Key for station sorting
sub _cmpstn 
{ 
    return $_[0]->{code}.' '.$_[0]->{solnid} 
};

sub _getStation
{
    my($self,$mcode,$solnid) = @_;
    my $stations=$self->{stations};
    if( ! exists($stations->{$mcode}) || ! exists($stations->{$mcode}->{$solnid}) )
    {
        my $newstn= {
            code=>$mcode,
            solnid=>$solnid,
            epoch=>0,
            prmoffset=>0,
            estimated=>0,
            xyz=>[0.0,0.0,0.0],
            covar=>[[0.0,0.0,0.0],[0.0,0.0,0.0],[0.0,0.0,0.0]]
            };
        $stations->{$mcode}->{$solnid} = $newstn;
    }
    return $stations->{$mcode}->{$solnid};
}

sub _compileStationList
{
    my($self)=@_;
    my $stations=$self->{stations};
    my @solnstns=();
    foreach my $k (%$stations)
    {
        push(@solnstns,grep {$_->{estimated}} values %{$stations->{$k}});
    }
    my $prmoffset=0;
    foreach my $sstn (sort {_cmpstn($a) cmp _cmpstn($b)} @solnstns)
    {
        $sstn->{prmoffset}=$prmoffset;
        $prmoffset += 3;
    }
    $self->{solnstns}=\@solnstns;
    $self->{nparam}=$prmoffset;
}


sub _scanSolutionEstimate
{
    my ($self,$sf)=@_;
    my $stations=$self->{stations};
    my $prms=$self->{solnprms};
    while( my $line=<$sf> )
    {
        my $ctl=substr($line,0,1);
        last if $ctl eq '-';
        next if $ctl eq '*';
        if( $ctl eq '+' )
        {
            carp("Invalid SINEX file - SOLUTION/ESTIMATE not terminated\n");
            last;
        }
        croak("Invalid SOLUTION/ESTIMATE line $line in ".$self->{filename}."\n")
        if $line !~ /^
             \s([\s\d]{5})  # param id
             \s([\s\w]{6})  # param type
             \s([\s\w]{4})  # point id
             \s([\s\w]{2})  # point code
             \s([\s\w]{4})  # solution id
             \s(\d\d\:\d\d\d\:\d\d\d\d\d) #parameter epoch
             \s([\s\w]{4})  # param units
             \s([\s\w]{1})  # param cnstraints
             \s([\s\dE\+\-\.]{21})  # param value
             \s([\s\dE\+\-\.]{11})  # param stddev
             \s*$/x;

        my ($id,$ptype,$mcode,$solnid,$epoch,$value)=
           (_trim($1)+0,_trim($2),_trim($3),_trim($4).':'._trim($5),_trim($6),_trim($9)+0);

        next if $ptype !~ /^STA([XYZ])$/;

        my $stn=$self->_getStation($mcode,$solnid);
        my $pno=index('XYZ',$1);
        $stn->{xyz}->[$pno]=$value;
        $stn->{estimated}=1;
        $prms->{$id}={stn=>$stn,pno=>$pno};
    }
    $self->_compileStationList();
    return 1;
}

sub _scanCovar
{
    my ($self,$sf,$fullcovar) = @_;
    my $fcvr=[[]];
    my $prms=$self->{solnprms};
    my $solnstns=$self->{solnstns};
    my $nparam=$self->{nparam};

    $self->{xyzcovar}=$fcvr;
    if( $fullcovar )
    {
        foreach my $iprm (0..$nparam-1)
        {
            $fcvr->[$iprm]=[(0)x($iprm+1)]
        }
    }

    while( my $line=<$sf> )
    {
        my $ctl=substr($line,0,1);
        last if $ctl eq '-';
        next if $ctl eq '*';
        if( $ctl eq '+' )
        {
            carp("Invalid SINEX file - SOLUTION/MATRIX_ESTIMATE not terminated\n");
            last;
        }
        croak("Invalid SOLUTION/MATRIX_ESTIMATE line $line in ".$self->{filename}."\n")
        if $line !~ /^
            \s([\s\d]{5})
            \s([\s\d]{5})
            \s([\s\dE\+\-\.]{21})
            (?:\s([\s\dE\+\-\.]{21}))?
            (?:\s([\s\dE\+\-\.]{21}))?
            /x;
        my ($p0,$p1,$cvc)=($1+0,$2+0,[_trim($3),_trim($4),_trim($5)]);
        next if ! exists $prms->{$p0};
        my $prm=$prms->{$p0};
        my $stn=$prm->{stn};
        my $pno=$prm->{pno};
        my $rc0=$stn->{prmoffset}+$pno;
        my $covar=$stn->{covar};

        foreach my $ip (0,1,2)
        {
            my $p1i=$p1+$ip;
            next if $cvc->[$ip] eq '';
            next if ! exists $prms->{$p1i};
            $prm=$prms->{$p1i};
            my $stnt=$prm->{stn};
            if( $fullcovar )
            {
                my $rc1=$stnt->{prmoffset}+$prm->{pno};
                if( $rc1 < $rc0 ){ $fcvr->[$rc0]->[$rc1]=$cvc->[$ip]+0; }
                else { $fcvr->[$rc1]->[$rc0]=$cvc->[$ip]+0; }
            }
            next if $stnt ne $stn;
            my $pno1=$prm->{pno};
            $covar->[$pno]->[$pno1]=$cvc->[$ip]+0;
            $covar->[$pno1]->[$pno]=$cvc->[$ip]+0;
        }
    }
    return 1;
}

sub _scanEpochs
{
    my ($self,$sf)=@_;
    while( my $line=<$sf> )
    {
        my $ctl=substr($line,0,1);
        last if $ctl eq '-';
        next if $ctl eq '*';
        if( $ctl eq '+' )
        {
            carp("Invalid SINEX file - SOLUTION/EPOCHS not terminated\n");
            last;
        }
        croak("Invalid SOLUTION/EPOCH line $line in ".$self->{filename}."\n")
        if $line !~ /^
            \s([\s\w]{4})  # point id
            \s([\s\w]{2})  # point code
            \s([\s\w]{4})  # solution id
            \s(\w)           # to be determined!
            \s(\d\d\:\d\d\d\:\d\d\d\d\d) # start epoch
            \s(\d\d\:\d\d\d\:\d\d\d\d\d) # end epoch
            \s(\d\d\:\d\d\d\:\d\d\d\d\d) # mean epoch
            /x;
        my ($code,$solnid,$meanepoch)=(_trim($1),_trim($2).':'._trim($3),$7);
        my ($y,$doy,$sec)=split(/\:/,$meanepoch);
        $y += 1900;
        $y += 100 if $y < 1980;
        my $epoch=yearday_seconds($y,$doy)+$sec;
        $self->_getStation($code,$solnid)->{epoch}=$epoch;
    }
    return 1;
}


=head2 $sf->filterStationsOnly($filteredsnx)

Creates a new version of the SINEX file containing only the station 
coordinate data.

=cut

sub filterStationsOnly
{
    my( $self, $filteredsnx ) = @_;
    my $source=$self->{filename};

    open( my $tgt, ">$filteredsnx" ) || croak("Cannot open output SINEX $filteredsnx\n");
    my $src=$self->_open();

    my $solnstns=$self->{solnstns};
    my $prms=$self->{solnprms};
    my $prmmap={};
    foreach my $k (keys %$prms)
    {
        my $prm=$prms->{$k};
        my $id=$prm->{stn}->{prmoffset}+$prm->{pno};
        $prmmap->{$k}=$id+1;
    }

    my $nprm=scalar(@$solnstns)*3;

    my $section='';
    while( my $line=<$src> )
    {
        if( $line =~ /^\%\=SNX/ )
        {
            substr($line,60,5)=sprintf("%05d",$nprm);
            substr($line,68)="S           \n";
        }
        elsif( $line =~ /^\+(.*?)\s*$/ )
        {
            $section=$1;
        }
        elsif( $line =~ /^\-/ )
        {
            $section='';
        }
        elsif( $line =~ /^\*/ )
        {
        }
        elsif( $section =~ /SOLUTION\/(ESTIMATE|APRIORI)/ )
        {
            $line =~ /^
               \s([\s\d]{5})  # param id
               /x;
            my $id=_trim($1)+0;
            next if ! exists $prmmap->{$id};
            substr($line,1,5)=sprintf("%5d",$prmmap->{$id});
        }
        elsif( $section =~ /SOLUTION\/MATRIX_(ESTIMATE|APRIORI)\s+L\s+COVA/ )
        {
            my $zero=sprintf("%21.14E",0.0);
            my $vcv=[];
            foreach my $i (0..$nprm-1)
            {
                $vcv->[$i]=[];
                foreach my $j (0..$i)
                {
                    $vcv->[$i]->[$j]=$zero;
                }
            }

            for( ; $line && $line !~ /^\-/; $line=<$src> )
            {
                if( $line =~ /^\*/ )
                {
                    next;
                }
                $line =~ /^
                    \s([\s\d]{5})
                    \s([\s\d]{5})
                    \s([\s\dE\+\-\.]{21})
                    (?:\s([\s\dE\+\-\.]{21}))?
                    (?:\s([\s\dE\+\-\.]{21}))?
                    /x;
                my ($p0,$p1,$cvc)=($1+0,$2+0,[$3,$4,$5]);
                next if ! exists $prmmap->{$p0};

                my $rc0=$prmmap->{$p0}-1;
                foreach my $ip (0,1,2)
                {
                    my $p1i=$p1+$ip;
                    next if $cvc->[$ip] eq '';
                    next if ! exists $prmmap->{$p1i};
                    my $rc1=$prmmap->{$p1i}-1;
                    if( $rc1 < $rc0 ){ $vcv->[$rc0]->[$rc1]=$cvc->[$ip]; }
                    else { $vcv->[$rc1]->[$rc0]=$cvc->[$ip]; }
                }
            }

            foreach my $i (1 .. $nprm)
            {
                my $ic=$i-1;
                for(my $j0=1; $j0 <= $i; $j0+=3 )
                {
                    printf $tgt " %5d %5d",$i,$j0;
                    foreach my $k (0 .. 2)
                    {
                        my $j=$j0+$k;
                        last if $j > $i;
                        print $tgt " ".$vcv->[$ic]->[$j-1];
                    }
                    print $tgt "\n";
                }
            }
            $section='';
        }
        print $tgt $line;
    }
    close($src);
    close($tgt);
}


1;
