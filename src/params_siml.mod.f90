module md_params_siml
  !////////////////////////////////////////////////////////////////
  !  Module contains simulation parameters read in by getpar_siml
  ! Copyright (C) 2015, see LICENSE, Benjamin David Stocker
  ! contact: b.stocker@imperial.ac.uk
  !----------------------------------------------------------------
  use md_sofunutils, only: getparint, getparstring, getparlogical

  implicit none

  private
  public paramstype_siml, getsteering, outtype_steering, getpar_siml

  type paramstype_siml
    
    integer :: runyears        ! number of years of entire simulation (spinup+transient)
    integer :: spinupyears     ! number of spinup years
    integer :: nyeartrend      ! number of transient years
    integer :: firstyeartrend  ! year AD of first transient year
    integer :: recycle         ! length of standard recycling period
    integer :: daily_out_startyr! first year where daily output is written
    integer :: daily_out_endyr ! last year where daily output is written
    
    logical :: do_spinup       ! whether this simulation does spinup 
    logical :: const_co2       ! is true when using constant CO2, given by first transient year in 'co2_forcing_file'
    logical :: const_ndep      ! is true when using constant N deposition, given by first transient year in 'ndep_forcing_file'
    logical :: const_nfert     ! is true when using constant N fertilisation, given by first transient year in 'nfert_forcing_file'
    logical :: const_clim      ! is true when using constant climate, given by year 'firstyeartrend'
    logical :: const_lu        ! is true when using constant land use, given by year 'firstyeartrend'
    
    character(len=256) :: runname
    character(len=256) :: sitename
    character(len=256) :: input_dir
    character(len=256) :: co2_forcing_file
    character(len=256) :: ndep_noy_forcing_file
    character(len=256) :: ndep_nhx_forcing_file
    character(len=256) :: nfert_noy_forcing_file
    character(len=256) :: nfert_nhx_forcing_file
    character(len=256) :: do_grharvest_forcing_file

    logical :: prescr_monthly_fapar

    ! activated PFTs
    logical :: lTeBS
    logical :: lGrC3
    logical :: lGNC3
    logical :: lGrC4

    ! booleans defining whether variable is written to output
    logical :: loutdgpp       
    logical :: loutdrd
    logical :: loutdtransp    
    logical :: loutdnpp       
    logical :: loutdnup       
    logical :: loutdcex       
    logical :: loutdCleaf     
    logical :: loutdCroot     
    logical :: loutdClabl     
    logical :: loutdNlabl     
    logical :: loutdClitt     
    logical :: loutdNlitt     
    logical :: loutdlai       
    logical :: loutdfapar
    logical :: loutdninorg    
    logical :: loutdtemp_soil 

    logical :: loutntransform
    logical :: loutwaterbal  
    logical :: loutlittersom
    logical :: loutnuptake

  end type paramstype_siml

  type outtype_steering
    integer :: year
    integer :: forcingyear     ! year AD for which forcings are read in (=firstyeartrend during spinup)
    integer :: climateyear     ! year AD for which climate is read in (recycling during spinup or when climate is held const.)
    integer :: outyear         ! year AD written to output
    logical :: spinup          ! is true during spinup
    logical :: init            ! is true in first simulation year
  end type

contains

  function getsteering( year, params_siml ) result( out_steering )
    !////////////////////////////////////////////////////////////////
    !  SR defines variables used for steering simulation for each 
    !  simulation year (setting booleans for opening files, doing   
    !  spinup etc.)
    !----------------------------------------------------------------
    ! arguments
    integer, intent(in) :: year
    type( paramstype_siml ), intent(in) :: params_siml

    ! local variables
    integer :: cycleyear

    ! function return variable
    type( outtype_steering ) :: out_steering

    out_steering%year = year
    
    if (params_siml%do_spinup) then
      if (year<=params_siml%spinupyears) then
        ! during spinup
        out_steering%spinup = .true.
        out_steering%forcingyear = params_siml%firstyeartrend
        cycleyear = get_cycleyear( year, params_siml%spinupyears, params_siml%recycle )
        out_steering%climateyear = cycleyear + params_siml%firstyeartrend - 1

      else  
        ! during transient simulation
        out_steering%spinup = .false.
        out_steering%forcingyear =  year - params_siml%spinupyears + params_siml%firstyeartrend - 1

        if (params_siml%const_clim) then
          ! constant climate flag activated
          cycleyear = get_cycleyear( year, params_siml%spinupyears, params_siml%recycle )
          out_steering%climateyear = cycleyear + params_siml%firstyeartrend - 1
        
        else
          ! constant climate flag not activated
          out_steering%climateyear = out_steering%forcingyear
        
        end if

      endif
      out_steering%outyear = year + params_siml%firstyeartrend - params_siml%spinupyears - 1

    else

      out_steering%forcingyear = year + params_siml%firstyeartrend - 1 
      out_steering%climateyear = out_steering%forcingyear
      out_steering%outyear = year + params_siml%firstyeartrend - 1

    endif

    if (year==1) then
      out_steering%init = .true.
    else
      out_steering%init = .false.
    endif 

    ! print*, 'out_steering%climateyear'
    ! print*, out_steering%climateyear
    ! if (year>30) stop

  end function getsteering


  function get_cycleyear( year, spinupyears, recycle ) result( cycleyear )
    !////////////////////////////////////////////////////////////////
    ! Returns cyce year for climate recycling, given number of spinup
    ! years and recycle period length, so that in the last year of
    ! of the spinup, 'cycleyear' is equal to 'recycle'.
    !----------------------------------------------------------------
    ! arguments
    integer, intent(in) :: year
    integer, intent(in) :: spinupyears
    integer, intent(in) :: recycle

    ! local variables
    integer :: remainder
    integer :: nfits
    integer :: first_cycleyear

    ! function return variable
    integer :: cycleyear

    remainder = mod( spinupyears, recycle )
    nfits = (spinupyears - remainder) / recycle
    first_cycleyear = recycle - remainder + 1
    cycleyear = modulo( first_cycleyear + year - 1, recycle )  
    if (cycleyear==0) cycleyear = recycle

  end function get_cycleyear


  function getpar_siml( runname ) result( out_getpar_siml )
    !////////////////////////////////////////////////////////////////
    !  SR for reading and defining simulation parameters from file 
    !  <runname>.sofun.parameter. Only once at start of simulation.
    !----------------------------------------------------------------
    ! argument
    character(len=*), intent(in) :: runname

    ! function return variable
    type( paramstype_siml ) :: out_getpar_siml

    ! Read in main model parameters
    write(0,*) 'reading parameter file ', runname//".sofun.parameter ..."

    out_getpar_siml%runname = runname

    ! sitename         = getparstring( 'run/'//runname//'.sofun.parameter', 'sitename' )
    ! input_dir        = getparstring( 'run/'//runname//'.sofun.parameter', 'input_dir' )
    ! co2_forcing_file = getparstring( 'run/'//runname//'.sofun.parameter', 'co2_forcing_file' )

    call getparstring( 'run/'//runname//'.sofun.parameter', 'sitename', out_getpar_siml%sitename )
    call getparstring( 'run/'//runname//'.sofun.parameter', 'input_dir', out_getpar_siml%input_dir )
    call getparstring( 'run/'//runname//'.sofun.parameter', 'co2_forcing_file', out_getpar_siml%co2_forcing_file )
    call getparstring( 'run/'//runname//'.sofun.parameter', 'ndep_noy_forcing_file', out_getpar_siml%ndep_noy_forcing_file )
    call getparstring( 'run/'//runname//'.sofun.parameter', 'ndep_nhx_forcing_file', out_getpar_siml%ndep_nhx_forcing_file )
    call getparstring( 'run/'//runname//'.sofun.parameter', 'nfert_noy_forcing_file', out_getpar_siml%nfert_noy_forcing_file )
    call getparstring( 'run/'//runname//'.sofun.parameter', 'nfert_nhx_forcing_file', out_getpar_siml%nfert_nhx_forcing_file )
    call getparstring( 'run/'//runname//'.sofun.parameter', 'do_grharvest_forcing_file', out_getpar_siml%do_grharvest_forcing_file )

    out_getpar_siml%do_spinup            = getparlogical( 'run/'//runname//'.sofun.parameter', 'spinup' )
    out_getpar_siml%const_co2            = getparlogical( 'run/'//runname//'.sofun.parameter', 'const_co2' )
    out_getpar_siml%const_ndep           = getparlogical( 'run/'//runname//'.sofun.parameter', 'const_ndep' )
    out_getpar_siml%const_nfert          = getparlogical( 'run/'//runname//'.sofun.parameter', 'const_nfert' )
    out_getpar_siml%const_clim           = getparlogical( 'run/'//runname//'.sofun.parameter', 'const_clim' )
    out_getpar_siml%const_lu             = getparlogical( 'run/'//runname//'.sofun.parameter', 'const_lu' )
    
    out_getpar_siml%spinupyears          = getparint( 'run/'//runname//'.sofun.parameter', 'spinupyears' )
    out_getpar_siml%firstyeartrend       = getparint( 'run/'//runname//'.sofun.parameter', 'firstyeartrend' )
    out_getpar_siml%nyeartrend           = getparint( 'run/'//runname//'.sofun.parameter', 'nyeartrend' )
    out_getpar_siml%recycle              = getparint( 'run/'//runname//'.sofun.parameter', 'recycle' )
    
    out_getpar_siml%prescr_monthly_fapar = getparlogical( 'run/'//runname//'.sofun.parameter', 'prescr_monthly_fapar' )
    
    out_getpar_siml%daily_out_startyr    = getparint( 'run/'//runname//'.sofun.parameter', 'daily_out_startyr' )
    out_getpar_siml%daily_out_endyr      = getparint( 'run/'//runname//'.sofun.parameter', 'daily_out_endyr' )

    if (out_getpar_siml%do_spinup) then
      out_getpar_siml%runyears = out_getpar_siml%nyeartrend + out_getpar_siml%spinupyears
    else
      out_getpar_siml%runyears = out_getpar_siml%nyeartrend
      out_getpar_siml%spinupyears = 0
    endif

    out_getpar_siml%lTeBS          = getparlogical( 'run/'//runname//'.sofun.parameter', 'lTeBS' )
    out_getpar_siml%lGrC3          = getparlogical( 'run/'//runname//'.sofun.parameter', 'lGrC3' )
    out_getpar_siml%lGNC3          = getparlogical( 'run/'//runname//'.sofun.parameter', 'lGNC3' )
    out_getpar_siml%lGrC4          = getparlogical( 'run/'//runname//'.sofun.parameter', 'lGrC4' )
    
    out_getpar_siml%loutdgpp       = getparlogical( 'run/'//runname//'.sofun.parameter', 'loutdgpp' )
    out_getpar_siml%loutdrd        = getparlogical( 'run/'//runname//'.sofun.parameter', 'loutdrd' )
    out_getpar_siml%loutdtransp    = getparlogical( 'run/'//runname//'.sofun.parameter', 'loutdtransp' )
    out_getpar_siml%loutdnpp       = getparlogical( 'run/'//runname//'.sofun.parameter', 'loutdnpp' )
    out_getpar_siml%loutdnup       = getparlogical( 'run/'//runname//'.sofun.parameter', 'loutdnup' )
    out_getpar_siml%loutdcex       = getparlogical( 'run/'//runname//'.sofun.parameter', 'loutdcex' )
    out_getpar_siml%loutdCleaf     = getparlogical( 'run/'//runname//'.sofun.parameter', 'loutdCleaf' )
    out_getpar_siml%loutdCroot     = getparlogical( 'run/'//runname//'.sofun.parameter', 'loutdCroot' )
    out_getpar_siml%loutdClabl     = getparlogical( 'run/'//runname//'.sofun.parameter', 'loutdClabl' )
    out_getpar_siml%loutdNlabl     = getparlogical( 'run/'//runname//'.sofun.parameter', 'loutdNlabl' )
    out_getpar_siml%loutdClitt     = getparlogical( 'run/'//runname//'.sofun.parameter', 'loutdClitt' )
    out_getpar_siml%loutdNlitt     = getparlogical( 'run/'//runname//'.sofun.parameter', 'loutdNlitt' )
    out_getpar_siml%loutdlai       = getparlogical( 'run/'//runname//'.sofun.parameter', 'loutdlai' )
    out_getpar_siml%loutdfapar     = getparlogical( 'run/'//runname//'.sofun.parameter', 'loutdfapar' )
    out_getpar_siml%loutdninorg    = getparlogical( 'run/'//runname//'.sofun.parameter', 'loutdninorg' )
    out_getpar_siml%loutdtemp_soil = getparlogical( 'run/'//runname//'.sofun.parameter', 'loutdtemp_soil' )
    
    out_getpar_siml%loutntransform = getparlogical( 'run/'//runname//'.sofun.parameter', 'loutntransform') 
    out_getpar_siml%loutwaterbal   = getparlogical( 'run/'//runname//'.sofun.parameter', 'loutwaterbal')
    out_getpar_siml%loutlittersom  = getparlogical( 'run/'//runname//'.sofun.parameter', 'loutlittersom' )
    out_getpar_siml%loutnuptake    = getparlogical( 'run/'//runname//'.sofun.parameter', 'loutnuptake' )

    write(0,*) "... done"

  end function getpar_siml

end module md_params_siml

