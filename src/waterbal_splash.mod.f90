module md_waterbal
  !////////////////////////////////////////////////////////////////
  ! SPLASH WATERBALANCE MODULE
  ! Contains the "main" subroutine 'waterbal' and all necessary 
  ! subroutines for handling input/output. 
  ! Every module that implements 'waterbal' must contain this list 
  ! of subroutines (names that way).
  !   - getpar_modl_waterbal
  !   - initio_waterbal
  !   - initoutput_waterbal
  !   - getout_daily_waterbal
  !   - getout_monthly_waterbal
  !   - writeout_ascii_waterbal
  !   - waterbal
  ! Required module-independent model state variables (necessarily 
  ! updated by 'waterbal') are:
  !   - daytime net radiation ('rn')
  !   - soil water conent ('psoilphys%wcont')
  !   - runoff ('soilphys%ro')
  ! Copyright (C) 2015, see LICENSE, Benjamin David Stocker
  ! contact: b.stocker@imperial.ac.uk
  ! ...
  !----------------------------------------------------------------
  use md_params_core, only: ndayyear, nmonth, nlu, maxgrid, kTo, kR, kMv, kMa, kfFEC

  implicit none

  private
  public solartype, soilphys, evap, waterbal, getsolar,                &
    initdaily_waterbal, initio_waterbal,                               &
    getout_daily_waterbal, initoutput_waterbal,                        &
    getpar_modl_waterbal, writeout_ascii_waterbal, initio_nc_waterbal, &
    writeout_nc_waterbal, get_rlm_waterbal

  !----------------------------------------------------------------
  ! Public, module-specific state variables
  !----------------------------------------------------------------
  ! Collection of physical soil variables used across modules
  type soilphystype
    real :: ro           ! daily runoff (mm)
    real :: sw           ! evaporative supply rate (mm/h)
    real :: wscal        ! water filled pore space (unitless)
    real :: fleach       ! NO3 leaching fraction (unitless)
    ! real :: soilmstress  ! soil moisture stress factor (unitless)
  end type soilphystype

  type( soilphystype ), dimension(nlu) :: soilphys(nlu)

  ! Collection of solar radiation-related variables used across modules
  ! Variables are a function of latitude, elevation, and 
  ! sunshine fraction (all variables independent of soil moisture)
  type solartype
    real, dimension(ndayyear) :: dayl        ! day length (hours)
    real, dimension(ndayyear) :: dra         ! daily TOA solar irradiation (J/m2)
    real, dimension(ndayyear) :: dppfd       ! daily total PPFD (mol m-2 d-1)
    real, dimension(nmonth)   :: mppfd       ! monthly total PPFD (mol m-2 month-1)
    real, dimension(nmonth)   :: meanmppfd   ! monthly mean PPFD, averaged over daylight seconds (mol m-2 s-1)
  end type solartype

  !-----------------------------------------------------------------------
  ! Uncertain (unknown) parameters. Runtime read-in
  !-----------------------------------------------------------------------
  real :: kA                ! constant for dRnl (Monteith & Unsworth, 1990)
  real :: kalb_sw           ! shortwave albedo (Federer, 1968)
  real :: kalb_vis          ! visible light albedo (Sellers, 1985)
  real :: kb                ! constant for dRnl (Linacre, 1968)
  real :: kc                ! cloudy transmittivity (Linacre, 1968)
  real :: kCw               ! supply constant, mm/hr (Federer, 1982)
  real :: kd                ! angular coefficient of transmittivity (Linacre, 1968)
  real :: ke                ! eccentricity for 2000 CE (Berger, 1978)
  real :: keps              ! obliquity for 2000 CE, degrees (Berger, 1978)
  real :: kGsc              ! solar constant, W/m^2 (Kopp & Lean, 2011)
  real :: kw                ! entrainment factor (Lhomme, 1997; Priestley & Taylor, 1972)
  real :: komega            ! longitude of perihelion for 2000 CE, degrees (Berger, 1978)

  !----------------------------------------------------------------
  ! MODULE-SPECIFIC, PRIVATE VARIABLES
  !----------------------------------------------------------------
  ! Orbit parameters 
  type outtype_berger
    real :: nu
    real :: lambda
  end type outtype_berger

  type( outtype_berger ), dimension(ndayyear) :: out_berger    ! stores output of function berger_tls

  ! Radiation variables. aet, sw, and cpa are affected by soil moisture.
  type evaptype
    real :: rn         ! daily net radiation (J/m2/d)
    real :: rnn        ! nighttime net radiation (J/m^2/d)
    real :: rnl        ! net longwave radiation (W/m^2)
    real :: eet        ! daily EET (mm d-1)
    real :: pet        ! daily PET (mm d-1)
    ! real :: pet_e      ! daily PET (J m-2 d-1)
    real :: cn         ! daily condensation (mm d-1)
    real :: aet        ! daily AET (mm d-1)
    ! real :: aet_e      ! daily AET (J m-2 d-1)
    real :: cpa        ! Cramer-Prentice-Alpha = AET / EET (unitless)
    real :: econ       ! water-to-energy conversion factor (econ), m^3/J
  end type evaptype

  ! SPLASH state variables
  type( evaptype ) , dimension(nlu) :: evap

  !----------------------------------------------------------------
  ! MODULE-SPECIFIC, KNOWN PARAMETERS
  !----------------------------------------------------------------
  real, parameter :: secs_per_day = 86400.0
  logical :: outenergy = .false.

  !----------------------------------------------------------------
  ! Module-specific rolling mean variables
  !----------------------------------------------------------------
  ! real, allocatable, dimension(:,:), save :: rlmalpha       ! rolling mean of annual mean alpha (AET/PET)
  integer, parameter :: nyrs_rlmalpha = 5                   ! number of years for rolling mean (=width of sliding window)

  !----------------------------------------------------------------
  ! Module-specific output variables, daily
  !----------------------------------------------------------------
  real, allocatable, dimension(:,:,:) :: outdwcont          ! daily water content = soil moisture, mm
  real, allocatable, dimension(:,:)   :: outdra             ! daily solar irradiation, J/m2
  real, allocatable, dimension(:,:)   :: outdrn             ! daily net radiation, J/m2
  real, allocatable, dimension(:,:)   :: outdppfd           ! daily PPFD, mol/m2
  real, allocatable, dimension(:,:)   :: outdayl            ! daily day length, h
  real, allocatable, dimension(:,:)   :: outdcn             ! daily condensation water, mm
  real, allocatable, dimension(:,:,:) :: outdro             ! daily runoff, mm
  real, allocatable, dimension(:,:,:) :: outdfleach         ! daily NO3 leaching fraction, (unitless)
  real, allocatable, dimension(:,:)   :: outdeet            ! daily equilibrium ET, mm
  real, allocatable, dimension(:,:)   :: outdpet            ! daily potential ET, mm r J/m2/d depending on 'outenergy'
  real, allocatable, dimension(:,:,:) :: outdaet            ! daily actual ET, mm or J/m2/d depending on 'outenergy'
  real, allocatable, dimension(:,:,:) :: outdcpa            ! daily Cramer-Prentice-Alpha, (unitless)
  real, allocatable, dimension(:,:)   :: outdecon           ! daily water-to-energy conversion factor m TJ-1 = mm GJ-1

  !----------------------------------------------------------------
  ! Module-specific output variables, annual
  !----------------------------------------------------------------
  real, allocatable, dimension(:)     :: outapet            ! annual total potential ET, mm r J/m2/yr depending on 'outenergy'
  real, allocatable, dimension(:,:)   :: outaaet            ! annual total actual ET, mm or J/m2/yr depending on 'outenergy'
  real, allocatable, dimension(:,:)   :: outaalpha          ! annual mean AET/PET (of daily values!), unitless

  !----------------------------------------------------------------
  ! Module-specific NetCDF output file and variable names
  !----------------------------------------------------------------
  ! Annual output files
  character(len=256) :: ncoutfilnam_apet
  character(len=256) :: ncoutfilnam_aaet
  character(len=256) :: ncoutfilnam_aalpha

  ! Daily output files
  character(len=256) :: ncoutfilnam_dwcont
  character(len=256) :: ncoutfilnam_dppfd
  character(len=256) :: ncoutfilnam_dpet
  character(len=256) :: ncoutfilnam_daet

  character(len=*), parameter :: WCONT_NAME="wcont"
  character(len=*), parameter :: PPFD_NAME="ppfd"
  character(len=*), parameter :: PET_NAME="pet"
  character(len=*), parameter :: AET_NAME="aet"
  character(len=*), parameter :: ALPHA_NAME="alpha"

  character(len=7) :: in_ppfd       ! information whether PPFD is prescribed from meteo file for global attribute in NetCDF file

contains

  subroutine waterbal( phy, doy, jpngr, lat, elv, soilparams, pr, tc, sf, netrad, splashtest, lev_splashtest, testdoy )
    !/////////////////////////////////////////////////////////////////////////
    ! Calculates daily and monthly quantities for one year
    !-------------------------------------------------------------------------
    use md_params_core, only: ndayyear, ndaymonth, nlu, dummy
    use md_tile, only: psoilphystype
    use md_params_soil, only: paramtype_soil

    ! arguments
    type( psoilphystype ), dimension(nlu), intent(inout) :: phy
    integer, intent(in)                                  :: doy    ! day of year
    integer, intent(in)                                  :: jpngr  ! gridcell number
    real, intent(in)                                     :: lat    ! latitude (degrees)
    real, intent(in)                                     :: elv    ! altitude (m)
    type( paramtype_soil ), intent(in)                   :: soilparams
    real, intent(in)                                     :: pr     ! daily precip (mm) 
    real, intent(in)                                     :: tc     ! mean monthly temperature (deg C)
    real, intent(in)                                     :: sf     ! mean monthly sunshine fraction (unitless)
    real, intent(in)                                     :: netrad ! net radiation (W m-2), may be dummy (in which case this is not used)

    logical, intent(in) :: splashtest
    integer, intent(in) :: lev_splashtest
    integer, intent(in) :: testdoy

    ! local variables
    integer :: lu                        ! land unit (gridcell tile)
    integer :: moy                       ! month of year
    integer :: idx                       ! day of year corresponding to yesterday
    integer :: dm                        ! day of month

    ! xxx debug
    integer, save :: leaching_events = 0

    real, parameter :: sf_splashtest = 0.562000036
    real, parameter :: tc_splashtest = -40.2450562
    real, parameter :: sw_splashtest = 0.573677897

    if (splashtest) then
      print*,'sf_splashtest ', sf_splashtest
      print*,'tc_splashtest ', tc_splashtest
      print*,'sw_splashtest ', sw_splashtest
    end if

    ! Loop over gricell tiles
    do lu=1,nlu

      ! Calculate evaporative supply rate, mm/h
      soilphys(lu)%sw = kCw * phy(lu)%wcont / soilparams%whc

      ! Calculate radiation and evaporation quantities
      if (splashtest) then
        evap(lu) = getevap( lat=67.25, doy=55, elv=87.0, sf=sf_splashtest, tc=tc_splashtest, sw=sw_splashtest, netrad=dummy, splashtest=splashtest, testdoy=testdoy )
        if (lev_splashtest==2) stop 'end of splash test level 2'
      else
        ! print*,'calling evap with arguments ', lat, doy, elv, sf, tc, soilphys(lu)%sw
        evap(lu) = getevap( lat, doy, elv, sf, tc, soilphys(lu)%sw, netrad, splashtest, testdoy )
        ! print*,'... done'
      end if

      ! Update soil moisture
      phy(lu)%wcont = phy(lu)%wcont + pr + evap(lu)%cn - evap(lu)%aet

      ! Bucket model for runoff generation
      if (phy(lu)%wcont>soilparams%whc) then
        ! -----------------------------------
        ! Bucket is full 
        ! -----------------------------------
        ! * determine NO3 leaching fraction 
        soilphys(lu)%fleach = 1.0 - soilparams%whc / phy(lu)%wcont
        ! print*,'fleach ', soilphys(lu)%fleach
        ! leaching_events = leaching_events + 1

        ! * add remaining water to monthly runoff total
        soilphys(lu)%ro = phy(lu)%wcont - soilparams%whc

        ! * set soil moisture to capacity
        phy(lu)%wcont = soilparams%whc

      elseif (phy(lu)%wcont<0.0) then
        ! -----------------------------------
        ! Bucket is empty
        ! -----------------------------------
        ! * set soil moisture to zero
        evap(lu)%aet              = evap(lu)%aet + phy(lu)%wcont
        phy(lu)%wcont             = 0.0
        soilphys(lu)%ro           = 0.0
        soilphys(lu)%fleach       = 0.0

      else
        ! No runoff occurrs
        soilphys(lu)%ro     = 0.0
        soilphys(lu)%fleach = 0.0

      end if

      ! water-filled pore space
      soilphys(lu)%wscal = phy(lu)%wcont / soilparams%whc

      ! ! soil moisture stress function
      ! soilphys(lu)%soilmstress = calc_soilmstress( soilphys(lu)%wscal, rlmalpha(lu,jpngr), params_pft_plant(pft)%grass )  

    end do

  end subroutine waterbal


  function getsolar( lat, elv, sf, ppfd, splashtest, testdoy ) result( out_solar )
    !/////////////////////////////////////////////////////////////////////////
    ! This subroutine calculates daily PPFD. Code is an extract of the subroutine
    ! 'evap', adopted from the evap() function in GePiSaT (Python version). 
    ! This subroutine ('getsolar') is called before the daily loop.
    ! Output:
    ! - daily extraterrestrial solar radiation (dra), J/m^2
    ! - daily PPFD (dppfd), mol/m^2
    !-------------------------------------------------------------------------  
    use md_params_core, only: ndayyear, pi, dummy
    use md_sofunutils, only: daily2monthly

    ! arguments
    real, intent(in)                      :: lat           ! latitude, degrees
    real, intent(in)                      :: elv           ! elevation, metres
    real, intent(in), dimension(ndayyear) :: sf            ! fraction of sunshine hours 
    real, intent(in), dimension(ndayyear) :: ppfd          ! photon flux density (mol m-2 d-1), may be dummy (in which case this is not used)
    logical, intent(in)                   :: splashtest
    integer, intent(in)                   :: testdoy

    ! function return variable
    type( solartype ) :: out_solar

    ! local variables
    integer            :: doy
    real               :: dr                           ! distance factor
    real               :: delta                        ! declination angle 
    real               :: ru                           ! variable substitute for u
    real               :: rv                           ! variable substitute for v
    real               :: hs                           ! sunset hour angle
    real               :: tau                          ! transmittivity (unitless)
    real               :: rw                           ! variable substitute (W/m^2)
    real, dimension(2) :: out_ru_rv      ! function return variable containing 'ru' and 'rv'.

    real, dimension(ndayyear) :: daysecs ! daylight seconds for each DOY
    real, dimension(nmonth)   :: monsecs ! daylight seconds for each MOY

    ! initialise members of solartype
    out_solar%dayl(:)      = 0.0
    out_solar%dra(:)       = 0.0
    out_solar%dppfd(:)     = 0.0
    out_solar%mppfd(:)     = 0.0
    out_solar%meanmppfd(:) = 0.0

    do doy=1,ndayyear

      ! Test for comparison with Python SPLASH
      if (splashtest .and. doy==testdoy) print*,'day of year: ', doy

      ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
      ! 2. Calculate heliocentric longitudes (nu and lambda), degrees
      ! Store daily return values for later use in subroutine 'evap'.
      ! Other variables defined and over-written below may be stored
      ! for later use in 'evap' the same way. However function 
      ! 'out_berger' is by far the most expensive one. This is there-
      ! fore a compromise.
      ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
      ! Berger (1978)
      out_berger(doy) = get_berger_tls( doy )

      ! Test for comparison with Python SPLASH
      if (splashtest .and. doy==testdoy) print*,'true anomaly, nu: ', out_berger(doy)%nu
      if (splashtest .and. doy==testdoy) print*,'true longitude, lambda: ', out_berger(doy)%lambda

      ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
      ! 3. Calculate distance factor (dr), unitless
      ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
      dr = calc_dr( out_berger(doy)%nu )

      ! Test for comparison with Python SPLASH
      if (splashtest .and. doy==testdoy) print*,'distance factor, dr: ', dr

      ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
      ! 4. Calculate declination angle (delta), degrees
      ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
      delta = calc_delta( out_berger(doy)%lambda )

      ! Test for comparison with Python SPLASH
      if (splashtest .and. doy==testdoy) print*,'declination, delta: ', delta

      ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
      ! 5. Calculate variable substitutes (u and v), unitless
      ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
      out_ru_rv = calc_ru_rv( delta, lat )
      ru = out_ru_rv(1)
      rv = out_ru_rv(2)

      ! Test for comparison with Python SPLASH
      if (splashtest .and. doy==testdoy) print*,'variable substitute, ru: ', ru
      if (splashtest .and. doy==testdoy) print*,'variable substitute, rv: ', rv

      ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
      ! 6. Calculate the sunset hour angle (hs), degrees
      ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
      hs = calc_hs( ru, rv )

      ! Test for comparison with Python SPLASH
      if (splashtest .and. doy==testdoy) print*,'sunset angle, hs: ', hs

      ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
      ! 6.a Calculate day length from sunset hour angle, h
      ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
      out_solar%dayl(doy) = 24.0 * hs / 180.0  ! hs is in degrees (pi = 180 deg)

      ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
      ! 7. Calculate daily extraterrestrial solar radiation (dra), J/m^2/d
      ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
      ! Eq. 1.10.3, Duffy & Beckman (1993)
      out_solar%dra(doy) = ( secs_per_day / pi ) * kGsc * dr * ( radians(ru) * hs + rv * dgsin(hs) )

      ! Test for comparison with Python SPLASH
      if (splashtest .and. doy==testdoy) print*,'daily TOA radiation: ', (1.0e-6)*out_solar%dra(doy)

      ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
      ! 8. Calculate transmittivity (tau), unitless
      ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
      tau = calc_tau( sf(doy), elv )

      ! Test for comparison with Python SPLASH
      if (splashtest .and. doy==testdoy) print*,'transmittivity, tau: ', tau

      ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
      ! 9. Calculate daily PPFD (dppfd), mol/m^2
      ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
      if (ppfd(1)/=dummy) then
        out_solar%dppfd(doy) = ppfd(doy)
        in_ppfd = ".true. "
      else
        ! Eq. 57, SPLASH 2.0 Documentation
        out_solar%dppfd(doy) = (1.0e-6) * kfFEC * ( 1.0 - kalb_vis ) * tau * out_solar%dra(doy)
        in_ppfd = ".false."
      end if

      ! Test for comparison with Python SPLASH
      if (splashtest .and. doy==testdoy) print*,'daily PPFD: ', out_solar%dppfd(doy)

    end do

    ! Calculate monthly average daylight PPFD 
    daysecs(:)         = out_solar%dayl(:) * 60.0 * 60.0              ! conversion of daylight hours to seconds
    monsecs(:)         = daily2monthly( daysecs(:), "sum" )
    out_solar%mppfd(:) = daily2monthly( out_solar%dppfd(:), "sum" )   ! mol m-2 month-1

    ! In polar regions, 'monsecs' an be zero in winter months. PPFD is zero then too.
    where ( monsecs(:) > 0.0 )
      out_solar%meanmppfd(:) = out_solar%mppfd(:) / monsecs(:) ! mol m-2 s-1
    else where
      out_solar%meanmppfd(:) = 0.0
    end where

    !-------------------------------------------------------------   
    ! Refs: Allen, R.G. (1996), Assessing integrity of weather data for 
    !         reference evapotranspiration estimation, Journal of Irrigation
    !         and Drainage Engineering, vol. 122, pp. 97--106.
    !       Allen, R.G., L.S. Pereira, D. Raes, M. Smith (1998), 
    !         'Meteorological data,' Crop evapotranspiration - Guidelines for 
    !         computing crop water requirements - FAO Irrigation and drainage 
    !         paper 56, Food and Agriculture Organization of the United 
    !         Nations, online: http://www.fao.org/docrep/x0490e/x0490e07.htm
    !       Berger, A.L. (1978), Long-term variations of daily insolation and 
    !         quarternary climatic changes, Journal of Atmospheric Sciences, 
    !         vol. 35, pp. 2362--2367.
    !       Berger, A.L., M.F. Loutre, and C. Tricot (1993), Insolation and 
    !         Earth's orbital periods, J. Geophys. Res., 98, 10341--10362.
    !       Duffie, J. A. and W. A. Beckman (1991). Solar engineering of 
    !         thermal processes. 4th ed. New Jersey: John Wiley and Sons
    !       Federer (1982), Transpirational supply and demand: plant, soil, 
    !         and atmospheric effects evaluated by simulation, Water 
    !         Resources Research, vol. 18, no. 2, pp. 355--362.
    !       Ge, S., R.G. Smith, C.P. Jacovides, M.G. Kramer, R.I. Carruthers 
    !         (2011), Dynamics of photosynthetic photon flux density (PPFD) 
    !         and estimates in coastal northern California, Theoretical and 
    !         Applied Climatology, vol. 105, pp. 107--118.
    !       Henderson-Sellers, B. (1984), A new formula for latent heat of 
    !         vaporization of water as a function of temperature, Quarterly 
    !         Journal of the Royal Meteorological Society 110, pp. 1186–1190
    !       Linacre (1968), Estimating the net-radiation flux, Agricultural 
    !         Meteorology, vol. 5, pp. 49--63.
    !       Prentice, I.C., M.T. Sykes, W. Cramer (1993), A simulation model 
    !         for the transient effects of climate change on forest 
    !         landscapes, Ecological Modelling, vol. 65, pp. 51--70.
    !       Priestley, C.H.B. and R.J. Taylor (1972), On the assessment of 
    !         surface heat flux and evaporation using large-scale parameters, 
    !         Monthly Weather Review, vol. 100 (2), pp. 81--92.
    !       Spencer, J. W. (1971), Fourier series representation of the 
    !         position of the sun, Search, vol. 2, p. 172.
    !       Stine, W. B. and M. Geyer (2001). “Power from the Sun”. 
    !         online: http://www.powerfromthesun.net/Book/chapter03/chapter03
    !       Wetherald, R.T., S. Manabe (1972), Response to joint ocean-
    !         atmosphere model to the seasonal variation of the solar 
    !         radiation, Monthly Weather Review, vol. 100 (1), pp. 42--59.
    !       Woolf, H. M. (1968). On the computation of solar evaluation 
    !         angles and the determination of sunrise and sunset times. 
    !         Tech. rep. NASA-TM-X-164. National Aeronautics and Space 
    !         Administration (NASA).
    !-------------------------------------------------------------   
  end function getsolar


  function getevap( lat, doy, elv, sf, tc, sw, netrad, splashtest, testdoy ) result( out_evap )
    !/////////////////////////////////////////////////////////////////////////
    ! This subroutine calculates daily evaporation quantities. Code is 
    ! adopted from the evap() function in GePiSaT (Python version). 
    ! This subroutine ('evap') is called within the daily loop.
    ! Output:
    ! - daily net longwave radiation (out_evap%drnl), W/m^2
    ! - daily daytime net radiation (out_evap%drn), J/m^2
    ! - daily nighttime net radiation (out_evap%rnn), J/m^2
    ! - daily EET (out_evap%eet), mm
    ! - daily PET (out_evap%pet), mm
    ! - daily AET (out_evap%aet), mm
    ! - daily condensation (out_evap%cn), mm
    !-------------------------------------------------------------------------  
    use md_params_core, only: ndayyear, pi
    use md_sofunutils, only: calc_patm

    ! arguments
    real,    intent(in) :: lat           ! latitude, degrees
    integer, intent(in) :: doy           ! day of the year (formerly 'n')
    real,    intent(in) :: elv           ! elevation, metres
    real,    intent(in) :: sf            ! fraction of sunshine hours
    real,    intent(in) :: tc            ! mean daily air temperature, C
    real,    intent(in) :: sw            ! evaporative supply rate, mm/hr
    real,    intent(in) :: netrad        ! net radiation (W m-2)

    logical, intent(in) :: splashtest
    integer, intent(in) :: testdoy

    ! function return variable
    type( evaptype )  :: out_evap

    ! local variables
    real :: dr                           ! distance factor
    real :: delta                        ! declination angle 
    real :: ru                           ! variable substitute for u
    real :: rv                           ! variable substitute for v
    real :: hs                           ! sunset hour angle
    real :: tau                          ! transmittivity (unitless)
    real :: rw                           ! variable substitute (W/m^2)
    real :: hn                           ! net radiation cross-over hour angle
    real :: s                            ! slope of saturation vap press temp curve, Pa/K
    real :: pw                           ! density of water, kg/m^3
    real :: lv                           ! enthalpy of vaporization, J/kg
    real :: g                            ! psychrometric constant, Pa/K
    real :: econ                         ! Eq. 58, SPLASH 2.0 Documentation
    real :: rx                           ! variable substitute (mm/hr)/(W/m^2)
    real :: hi, cos_hi                   ! intersection hour angle, degrees
    real, dimension(2) :: out_ru_rv      ! function return variable containing 'ru' and 'rv'.

    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! 3. Calculate distance factor (dr), unitless
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    dr = calc_dr( out_berger(doy)%nu )
    
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! 4. Calculate declination angle (delta), degrees
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    delta = calc_delta( out_berger(doy)%lambda )

    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! 5. Calculate variable substitutes (u and v), unitless
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    out_ru_rv = calc_ru_rv( delta, lat )
    ru = out_ru_rv(1)
    rv = out_ru_rv(2)

    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! 6. Calculate the sunset hour angle (hs), degrees
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    hs = calc_hs( ru, rv )
    
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! 8. Calculate transmittivity (tau), unitless
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    tau = calc_tau( sf, elv )

    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! 10. Estimate net longwave radiation (out_evap%rnl), W/m^2
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! Eq. 11, Prentice et al. (1993); Eq. 5 and 6, Linacre (1968)
    out_evap%rnl = ( kb + (1.0 - kb ) * sf ) * ( kA - tc )

    print*,'net longwave radiation: ', out_evap%rnl

    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! 11. Calculate variable substitute (rw), W/m^2
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    rw = ( 1.0 - kalb_sw ) * tau * kGsc * dr
    
    print*,'variable substitute, rw: ', rw

    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! 12. Calculate net radiation cross-over hour angle (hn), degrees
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    if ((out_evap%rnl - rw*ru)/(rw*rv) >= 1.0) then
      ! Net radiation negative all day
      hn = 0.0
    else if ((out_evap%rnl - rw*ru)/(rw*rv) <= -1.0) then
      ! Net radiation positive all day
      hn = 180.0
    else
      !hn = degrees( dacos((out_evap%rnl - rw*ru)/(rw*rv)) )
      hn = degrees( acos((out_evap%rnl - rw*ru)/(rw*rv)) )   ! use acos with single precision compilation
    end if

    print*,'cross-over hour angle: ', hn

    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! 13. Calculate daytime net radiation (out_evap%rn), J/m^2
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! Eq. 53, SPLASH 2.0 Documentation
    out_evap%rn = (secs_per_day/pi) * (hn*(pi/180.0)*(rw*ru - out_evap%rnl) + rw*rv*dgsin(hn))

    print*,'daytime net radiation: ', out_evap%rn

    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! 14. Calculate nighttime net radiation (out_evap%rnn), J/m^2
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! Eq. 56, SPLASH 2.0 Documentation
    ! adopted bugfix from Python version (iss#13)
    out_evap%rnn = (86400.0/pi)*(radians(rw*ru*(hs-hn)) + rw*rv*(dgsin(hs)-dgsin(hn)) - out_evap%rnl * (pi - radians(hn)))

    print*,'nighttime net radiation: ', out_evap%rnn

    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! 15. Calculate water-to-energy conversion (econ), m^3/J
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! Slope of saturation vap press temp curve, Pa/K
    s = sat_slope(tc)
    print*,'slope of saturation, s', s

    ! Enthalpy of vaporization, J/kg
    lv = enthalpy_vap(tc)
    print*,'enthalpy of vaporization: ', lv

    ! Density of water, kg/m^3
    pw = density_h2o(tc, calc_patm(elv))
    print*,'water density at 1 atm calculated: ', pw

    ! Psychrometric constant, Pa/K
    print*,'calculating psychrometric const. with (tc, elv): ', tc, elv
    g = psychro(tc, calc_patm(elv))
    print*,'calculating psychrometric const. with patm: ', calc_patm(elv)
    print*,'psychrometric constant: ', g

    ! Eq. 51, SPLASH 2.0 Documentation
    econ = s/(lv*pw*(s + g))
    print*,'Econ: ', Econ

    out_evap%econ = 1.0 / ( lv * pw ) ! this is to convert energy into mass (water)

    ! print*,'Econ alternative: ', 1.0 / (lv * pw)

    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! 16. Calculate daily condensation (out_evap%cn), mm d-1
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! Eq. 68, SPLASH 2.0 Documentation
    out_evap%cn = 1000.0 * econ * abs(out_evap%rnn)
    print*,'daily condensation: ', out_evap%cn

    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! 17. Estimate daily EET (out_evap%eet), mm d-1
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! Eq. 70, SPLASH 2.0 Documentation
    out_evap%eet = 1000.0 * econ * out_evap%rn
    print*,'daily EET: ', out_evap%eet

    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! 18. Estimate daily PET (out_evap%pet), mm d-1
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! Eq. 72, SPLASH 2.0 Documentation
    out_evap%pet   = ( 1.0 + kw ) * out_evap%eet
    print*,'daily PET: ', out_evap%pet
    ! out_evap%pet_e = out_evap%pet / (econ * 1000)

    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! 19. Calculate variable substitute (rx), (mm/hr)/(W/m^2)
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    rx = 1000.0 * 3600.0 * ( 1.0 + kw ) * econ
    print*,'variable substitute, rx: ', rx
    
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! 20. Calculate the intersection hour angle (hi), degrees
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    cos_hi = sw/(rw*rv*rx) + out_evap%rnl/(rw*rv) - ru/rv   ! sw contains info of soil moisture (evaporative supply rate)
    if (cos_hi >= 1.0) then
      ! Supply exceeds demand:
      hi = 0.0
    elseif (cos_hi <= -1.0) then
      ! Supply limits demand everywhere:
      hi = 180.0
    else
      hi = degrees(acos(cos_hi))
    end if
    print*,'intersection hour angle, hi: ', hi

    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! 21. Estimate daily AET (out_evap%aet), mm d-1
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! Eq. 81, SPLASH 2.0 Documentation
    out_evap%aet = (24.0/pi)*(radians(sw*hi) + rx*rw*rv*(dgsin(hn) - dgsin(hi)) + radians((rx*rw*ru - rx*out_evap%rnl)*(hn - hi)))
    ! out_evap%aet_e = out_evap%aet / (econ * 1000)
    print*,'daily AET set to: ', out_evap%aet
    stop 'waterbal()'

    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! 22. Calculate Cramer-Prentice-Alpha, (unitless)
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    if (out_evap%eet>0.0) then 
      out_evap%cpa = out_evap%aet / out_evap%eet
    else
      out_evap%cpa = 1.0 + kw
    end if

    ! ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! ! 23. CRUDEFIX: When temperature is below zero, set bot PET and AET to zero. 
    ! ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! if (tc < 0.0) then
    !   out_evap%pet = 0.0
    !   out_evap%eet = 0.0
    !   out_evap%aet = 0.0
    ! end if

    ! ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! ! 24. CRUDEFIX: When AET > PET, set AET to PET
    ! ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! if (out_evap%aet > out_evap%pet) then
    !   out_evap%aet = out_evap%pet
    ! end if

    ! ! checks
    ! if (out_evap%pet< -5.0) then
    !   print*,'doy:', doy
    !   print*,'lat', lat
    !   print*,'doy', doy
    !   print*,'elv', elv
    !   print*,'sf', sf
    !   print*,'tc', tc
    !   print*,'sw', sw
    !   print*,'pet', out_evap%pet
    !   stop 'pet < -5.0'
    ! end if

    ! if (out_evap%aet>out_evap%pet) then
    !   print*,'doy:', doy
    !   print*,'lat', lat
    !   print*,'doy', doy
    !   print*,'elv', elv
    !   print*,'sf', sf
    !   print*,'tc', tc
    !   print*,'sw', sw
    !   stop 'aet > pet'
    ! end if

    !-------------------------------------------------------------   
    ! Refs: Allen, R.G. (1996), Assessing integrity of weather data for 
    !         reference evapotranspiration estimation, Journal of Irrigation
    !         and Drainage Engineering, vol. 122, pp. 97--106.
    !       Allen, R.G., L.S. Pereira, D. Raes, M. Smith (1998), 
    !         'Meteorological data,' Crop evapotranspiration - Guidelines for 
    !         computing crop water requirements - FAO Irrigation and drainage 
    !         paper 56, Food and Agriculture Organization of the United 
    !         Nations, online: http://www.fao.org/docrep/x0490e/x0490e07.htm
    !       Berger, A.L. (1978), Long-term variations of daily insolation and 
    !         quarternary climatic changes, Journal of Atmospheric Sciences, 
    !         vol. 35, pp. 2362--2367.
    !       Berger, A.L., M.F. Loutre, and C. Tricot (1993), Insolation and 
    !         Earth's orbital periods, J. Geophys. Res., 98, 10341--10362.
    !       Duffie, J. A. and W. A. Beckman (1991). Solar engineering of 
    !         thermal processes. 4th ed. New Jersey: John Wiley and Sons
    !       Federer (1982), Transpirational supply and demand: plant, soil, 
    !         and atmospheric effects evaluated by simulation, Water 
    !         Resources Research, vol. 18, no. 2, pp. 355--362.
    !       Ge, S., R.G. Smith, C.P. Jacovides, M.G. Kramer, R.I. Carruthers 
    !         (2011), Dynamics of photosynthetic photon flux density (PPFD) 
    !         and estimates in coastal northern California, Theoretical and 
    !         Applied Climatology, vol. 105, pp. 107--118.
    !       Henderson-Sellers, B. (1984), A new formula for latent heat of 
    !         vaporization of water as a function of temperature, Quarterly 
    !         Journal of the Royal Meteorological Society 110, pp. 1186–1190
    !       Linacre (1968), Estimating the net-radiation flux, Agricultural 
    !         Meteorology, vol. 5, pp. 49--63.
    !       Prentice, I.C., M.T. Sykes, W. Cramer (1993), A simulation model 
    !         for the transient effects of climate change on forest 
    !         landscapes, Ecological Modelling, vol. 65, pp. 51--70.
    !       Priestley, C.H.B. and R.J. Taylor (1972), On the assessment of 
    !         surface heat flux and evaporation using large-scale parameters, 
    !         Monthly Weather Review, vol. 100 (2), pp. 81--92.
    !       Spencer, J. W. (1971), Fourier series representation of the 
    !         position of the sun, Search, vol. 2, p. 172.
    !       Stine, W. B. and M. Geyer (2001). “Power from the Sun”. 
    !         online: http://www.powerfromthesun.net/Book/chapter03/chapter03
    !       Wetherald, R.T., S. Manabe (1972), Response to joint ocean-
    !         atmosphere model to the seasonal variation of the solar 
    !         radiation, Monthly Weather Review, vol. 100 (1), pp. 42--59.
    !       Woolf, H. M. (1968). On the computation of solar evaluation 
    !         angles and the determination of sunrise and sunset times. 
    !         Tech. rep. NASA-TM-X-164. National Aeronautics and Space 
    !         Administration (NASA).
    !-------------------------------------------------------------   
  end function getevap


  function calc_dr( nu ) result( dr )
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! Calculates distance factor (dr), unitless
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! arguments
    real, intent(in) :: nu

    ! local variables
    real :: rho

    ! function return variable
    real :: dr

    ! Berger et al. (1993)
    rho = (1.0 - ke**2)/(1.0 + ke * dgcos( nu ))        
    dr = (1.0/rho)**2

  end function calc_dr


  function calc_delta( lambda ) result( delta )
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! Calculates declination angle (delta), degrees
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! arguments
    real, intent(in) :: lambda

    ! function return variable
    real :: delta

    ! Woolf (1968)
    delta = asin( dgsin( lambda ) * dgsin( keps ) )   ! xxx use asin with single-precision compilation
    delta = degrees( delta )

  end function calc_delta


  function calc_ru_rv( delta, lat ) result( out_ru_rv )
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! Calculates variable substitutes (u and v), unitless
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! arguments
    real, intent(in) :: delta
    real, intent(in) :: lat

    ! local variables
    real :: ru, rv

    ! function return variable
    real, dimension(2) :: out_ru_rv

    ru = dgsin(delta) * dgsin(lat)
    rv = dgcos(delta) * dgcos(lat)

    out_ru_rv(1) = ru
    out_ru_rv(2) = rv

  end function calc_ru_rv


  function calc_hs( ru, rv ) result( hs )
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! Calculates the sunset hour angle (hs), degrees
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! arguments
    real, intent(in) :: ru, rv

    ! function return variable
    real :: hs

    ! Note: u/v == tan(delta)*tan(lat)
    ! Eq. 3.22, Stine & Geyer (2001)
    if ((ru/rv) >= 1.0) then
      ! Polar day (no sunset)
      hs = 180.0 
    elseif ((ru/rv) <= -1.0) then
      ! Polar night (no sunrise)
      hs = 0.0
    else
      hs = degrees(acos(-1.0*ru/rv))
    end if

  end function calc_hs


  function calc_tau( sf, elv ) result( tau )
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! Calculates transmittivity (tau), unitless
    ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    ! arguments
    real, intent(in) :: sf     ! sunshine fraction
    real, intent(in) :: elv    ! elevation

    ! local variables
    real :: tau_o

    ! function return variable
    real :: tau

    ! Eq. 11, Linacre (1968)
    tau_o = (kc + kd*sf)

    ! Eq. 2, Allen (1996)
    tau = tau_o*(1.0 + (2.67e-5)*elv)

  end function calc_tau


  subroutine getpar_modl_waterbal()
    !////////////////////////////////////////////////////////////////
    ! Subroutine reads waterbalance module-specific parameters 
    ! from input file
    !----------------------------------------------------------------
    use md_sofunutils, only: getparreal

    print*,'reading waterbal parameters ...'

    ! constant for dRnl (Monteith & Unsworth, 1990)
    kA       = getparreal( 'params/params_waterbal_splash.dat', 'kA' )
    
    ! shortwave albedo (Federer, 1968)
    kalb_sw  = getparreal( 'params/params_waterbal_splash.dat', 'kalb_sw' )
    
    ! visible light albedo (Sellers, 1985) xxx planetary albedo? xxx
    kalb_vis = getparreal( 'params/params_waterbal_splash.dat', 'kalb_vis' )
    
    ! constant for dRnl (Linacre, 1968)
    kb       = getparreal( 'params/params_waterbal_splash.dat', 'kb' )
    
    ! cloudy transmittivity (Linacre, 1968)
    kc       = getparreal( 'params/params_waterbal_splash.dat', 'kc' )
    
    ! supply constant, mm/hr (Federer, 1982)
    kCw      = getparreal( 'params/params_waterbal_splash.dat', 'kCw' )
    
    ! angular coefficient of transmittivity (Linacre, 1968)
    kd       = getparreal( 'params/params_waterbal_splash.dat', 'kd' )
    
    ! eccentricity for 2000 CE (Berger, 1978)
    ke       = getparreal( 'params/params_waterbal_splash.dat', 'ke' )
    
    ! obliquity for 2000 CE, degrees (Berger, 1978)
    keps     = getparreal( 'params/params_waterbal_splash.dat', 'keps' )

    ! solar constant, W/m^2 (Kopp & Lean, 2011)
    kGsc     = getparreal( 'params/params_waterbal_splash.dat', 'kGsc' )
    
    ! entrainment factor (Lhomme, 1997; Priestley & Taylor, 1972)
    kw       = getparreal( 'params/params_waterbal_splash.dat', 'kw' )
    
    ! longitude of perihelion for 2000 CE, degrees (Berger, 1978)
    komega   = getparreal( 'params/params_waterbal_splash.dat', 'komega' )

    print*,'... done'

  end subroutine getpar_modl_waterbal

  ! xxx put these functions into a 'contain' within calling SR?

  function dgcos( x ) result( dgcos_out )
    !----------------------------------------------------------------   
    ! Calculates the cosine of an angle given in degrees. Equal to 
    ! 'dsin' in Python version.
    !----------------------------------------------------------------   
    use md_params_core, only: pi

    ! arguments
    real, intent(in) :: x  ! angle, degrees (0-360)

    ! function return value
    real :: dgcos_out ! cosine value of x when x is in degrees

    !dgcos = dcos(x*pi/180.0)
    dgcos_out = cos(x*pi/180.0)  ! xxx use cos with single-precision compilation

  end function dgcos


  function dgsin( x ) result( dgsin_out )
    !----------------------------------------------------------------   
    ! Calculates the sinus of an angle given in degrees. Equal to 
    ! 'dsin' in Python version.
    !----------------------------------------------------------------   
    use md_params_core, only: pi

    ! arguments
    real, intent(in) :: x  ! angle, degrees (0-360)

    ! function return value
    real :: dgsin_out ! sinus value of x when x is in degrees

    !dgsin_out = dsin(x*pi/180.0)
    dgsin_out = sin(x*pi/180.0)   ! xxx use cos with single-precision compilation

  end function dgsin


  function degrees( x ) result( degrees_out )
    !----------------------------------------------------------------   
    ! Returns corresponding degrees if x is given in radians
    !----------------------------------------------------------------   
    use md_params_core, only: pi

    ! arguments
    real, intent(in) :: x  ! angle, radians

    ! function return value
    real :: degrees_out

    degrees_out = x*180.0/pi

  end function degrees


  function radians( x ) result( radians_out )
    !----------------------------------------------------------------   
    ! Returns corresponding radians if x is given in degrees
    !----------------------------------------------------------------   
    use md_params_core, only: pi

    ! arguments
    real, intent(in) :: x  ! angle, radians

    ! function return value
    real :: radians_out

    radians_out = x*pi/180.0

  end function radians


  function get_berger_tls( day ) result( out_berger )
    !----------------------------------------------------------------   
    ! Returns true anomaly and true longitude for a given day
    ! Reference: Berger, A. L. (1978), Long term variations of daily 
    ! insolation and quaternary climatic changes, J. Atmos. Sci., 35, 
    ! 2362-2367.
    !----------------------------------------------------------------   
    ! arguments
    integer, intent(in) :: day   ! day of the year

    ! function return value
    type(outtype_berger) :: out_berger  ! stores output of function berger_tls

    ! local variables
    real :: anm, ranm, anv, ranv
    real :: dlamm                ! Mean longitude for day of year
    real :: my_nu
    real :: my_tls
    real :: xee, xec, xse        ! variable substitutes
    real :: xlam                 ! Mean longitude for vernal equinox
    real :: tmp1, tmp2, tmp3     ! variable substitutes

    ! Variable substitutes:
    xee = ke**2 
    xec = ke**3
    xse = sqrt(1.0 - xee)

    ! Mean longitude for vernal equinox:
    tmp1 = (ke/2.0 + xec/8.0)*(1.0 + xse)*dgsin(komega)
    tmp2 = xee/4.0*(0.5 + xse)*dgsin(2.0*komega)
    tmp3 = xec/8.0*(1.0/3.0 + xse)*dgsin(3.0*komega)
    xlam = tmp1 - tmp2 + tmp3
    xlam = degrees(2.0*xlam)

    ! Mean longitude for day of year:
    dlamm = xlam + (day - 80.0)*(360.0/ndayyear)

    ! Mean anomaly:
    anm = dlamm - komega
    ranm = radians(anm)

    ! True anomaly:
    ranv = (ranm + (2.0*ke - xec/4.0)*sin(ranm) + 5.0/4.0*xee*sin(2.0*ranm) + 13.0/12.0*xec*sin(3.0*ranm))  ! xxx use sin with single-precision compilation
    anv = degrees(ranv)

    ! True longitude:
    out_berger%lambda = anv + komega
    if (out_berger%lambda < 0.0) then
        out_berger%lambda = out_berger%lambda + 360.0
    else if (out_berger%lambda > 360.0) then
        out_berger%lambda = out_berger%lambda - 360.0
    endif

    ! True anomaly:
    out_berger%nu = (out_berger%lambda - komega)
    if (out_berger%nu < 0.0) then
        out_berger%nu = out_berger%nu + 360.0
    endif

  end function get_berger_tls


  function sat_slope( tc )
    !----------------------------------------------------------------   
    ! Calculates the slope of the sat pressure temp curve, Pa/K
    ! Ref:      Eq. 13, Allen et al. (1998)
    !----------------------------------------------------------------   
    ! arguments
    real, intent(in) :: tc ! air temperature, degrees C

    ! function return value
    real :: sat_slope  ! slope of the sat pressure temp curve, Pa/K

    sat_slope = (17.269)*(237.3)*(610.78)*(exp(tc*17.269/(tc + 237.3))/((tc + 237.3)**2))

  end function sat_slope


  function enthalpy_vap( tc )
    !----------------------------------------------------------------   
    ! Calculates the enthalpy of vaporization, J/kg
    ! Ref:      Eq. 8, Henderson-Sellers (1984)
    !----------------------------------------------------------------   

    ! arguments
    real, intent(in) :: tc ! air temperature, degrees C

    ! function return value
    real ::  enthalpy_vap ! enthalpy of vaporization, J/kg

    enthalpy_vap = 1.91846e6*((tc + 273.15)/(tc + 273.15 - 33.91))**2

  end function enthalpy_vap


  function density_h2o( tc, press )
    !----------------------------------------------------------------   
    ! Calculates density of water at a given temperature and pressure
    ! Ref: Chen et al. (1977)
    !----------------------------------------------------------------   

    ! arguments
    real, intent(in) :: tc     ! air temperature (degrees C)
    real, intent(in) :: press  ! atmospheric pressure (Pa)

    ! local variables
    real :: po, ko, ca, cb
    real :: pbar               ! atmospheric pressure (bar)

    ! function return value
    real :: density_h2o  ! density of water, kg/m^3

    ! Calculate density at 1 atm:
    po = (&
             0.99983952&
             + 6.788260e-5  *tc&
             - 9.08659e-6   *tc*tc&
             + 1.022130e-7  *tc*tc*tc  &
             - 1.35439e-9   *tc*tc*tc*tc&
             + 1.471150e-11 *tc*tc*tc*tc*tc&
             - 1.11663e-13  *tc*tc*tc*tc*tc*tc&
             + 5.044070e-16 *tc*tc*tc*tc*tc*tc*tc&
             - 1.00659e-18  *tc*tc*tc*tc*tc*tc*tc*tc&
         )

    ! Calculate bulk modulus at 1 atm:
    ko = (&
             19652.17&
             + 148.1830   *tc&
             - 2.29995    *tc*tc&
             + 0.01281    *tc*tc*tc&
             - 4.91564e-5 *tc*tc*tc*tc&
             + 1.035530e-7*tc*tc*tc*tc*tc&
         )

    ! Calculate temperature dependent coefficients:
    ca = (&
             3.26138&
             + 5.223e-4  *tc&
             + 1.324e-4  *tc*tc&
             - 7.655e-7  *tc*tc*tc&
             + 8.584e-10 *tc*tc*tc*tc&
         )
    cb = (&
             7.2061e-5&
             - 5.8948e-6  *tc&
             + 8.69900e-8 *tc*tc&
             - 1.0100e-9  *tc*tc*tc&
             + 4.3220e-12 *tc*tc*tc*tc&
         )

    ! Convert atmospheric pressure to bar (1 bar = 100000 Pa)
    pbar = (1.0e-5)*press

    density_h2o = 1000.0*po*(ko + ca*pbar + cb*pbar**2.0) &
      /(ko + ca*pbar + cb*pbar**2.0 - pbar)

  end function density_h2o


  function psychro( tc, press )
    !----------------------------------------------------------------   
    ! Calculates the psychrometric constant for a given temperature and pressure
    ! Ref: Allen et al. (1998); Tsilingiris (2008) 
    !----------------------------------------------------------------   
    ! arguments
    real, intent(in) :: tc     ! air temperature, degrees C
    real, intent(in) :: press  ! atmospheric pressure, Pa

    ! local variables
    real :: lv  ! latent heat of vaporization (J/kg)
    real :: cp

    ! function return value
    real :: psychro  ! psychrometric constant, Pa/K

    ! local variables
    real :: my_tc    ! adjusted temperature to avoid numerical blow-up 

    ! Adopted temperature adjustment from SPLASH, Python version
    my_tc = tc
    if (my_tc < 0) then
      my_tc = 0.0
    else if (my_tc > 100) then
      my_tc = 100.0
    end if

    ! Calculate the specific heat capacity of water, J/kg/K
    ! Eq. 47, Tsilingiris (2008)
    cp = 1.0e3*(&
               1.0045714270&
             + 2.050632750e-3  *my_tc&
             - 1.631537093e-4  *my_tc*my_tc&
             + 6.212300300e-6  *my_tc*my_tc*my_tc&
             - 8.830478888e-8  *my_tc*my_tc*my_tc*my_tc&
             + 5.071307038e-10 *my_tc*my_tc*my_tc*my_tc*my_tc&
            )

    ! Calculate latent heat of vaporization, J/kg
    lv = enthalpy_vap(tc)

    ! Calculate psychrometric constant, Pa/K
    ! Eq. 8, Allen et al. (1998)
    psychro = cp*kMa*press/(kMv*lv)

  end function psychro


  subroutine initdaily_waterbal()
    !////////////////////////////////////////////////////////////////
    ! Initialises all daily variables within derived type 'soilphys'.
    !----------------------------------------------------------------
    soilphys(:)%ro          = 0.0
    soilphys(:)%sw          = 0.0
    soilphys(:)%wscal       = 0.0
    ! soilphys(:)%soilmstress = 0.0

  end subroutine initdaily_waterbal


  subroutine initio_waterbal()
    !////////////////////////////////////////////////////////////////
    ! OPEN ASCII OUTPUT FILES FOR OUTPUT
    !----------------------------------------------------------------
    use md_interface, only: interface

    ! local variables
    character(len=256) :: prefix
    character(len=256) :: filnam

    prefix = "./output/"//trim(interface%params_siml%runname)

    !----------------------------------------------------------------
    ! DAILY OUTPUT
    !----------------------------------------------------------------
    if (interface%params_siml%loutwaterbal) then

      ! ! RA: daily solar irradiation, J/m2
      ! filnam=trim(prefix)//'.d.ra.out'
      ! open(251,file=filnam,err=888,status='unknown')

      ! ! RN: daily net radiation, J/m2
      ! filnam=trim(prefix)//'.d.rn.out'
      ! open(252,file=filnam,err=888,status='unknown')

      ! PPFD: daily PPFD, mol/m2
      filnam=trim(prefix)//'.d.ppfd.out'
      open(253,file=filnam,err=888,status='unknown')

      ! ! CN: daily condensation water, mm
      ! filnam=trim(prefix)//'.d.cn.out'
      ! open(254,file=filnam,err=888,status='unknown')

      ! WCONT: daily soil moisture, mm
      filnam=trim(prefix)//'.d.wcont.out'
      open(255,file=filnam,err=888,status='unknown')

      ! ! ! PN: daily precipitation, mm
      ! ! filnam=trim(prefix)//'.d.pn.out'
      ! ! open(256,file=filnam,err=888,status='unknown')

      ! ! RO: daily runoff, mm
      ! filnam=trim(prefix)//'.d.ro.out'
      ! open(257,file=filnam,err=888,status='unknown')

      ! ! FLEACH: daily leaching fraction, (unitless)
      ! filnam=trim(prefix)//'.d.fleach.out'
      ! open(263,file=filnam,err=888,status='unknown')

      ! ! eet: daily equilibrium ET, mm
      ! filnam=trim(prefix)//'.d.eet.out'
      ! open(258,file=filnam,err=888,status='unknown')

      ! PET: daily potential ET, mm
      filnam=trim(prefix)//'.d.pet.out'
      open(259,file=filnam,err=888,status='unknown')

      ! AET: daily actual ET, mm
      filnam=trim(prefix)//'.d.aet.out'
      open(260,file=filnam,err=888,status='unknown')

      ! ! DAYL: day length, h
      ! filnam=trim(prefix)//'.d.dayl.out'
      ! open(261,file=filnam,err=888,status='unknown')

      ! ! CPA: cramer-prentice alpha, unitless
      ! filnam=trim(prefix)//'.d.cpa.out'
      ! open(262,file=filnam,err=888,status='unknown')

      ! ! ECON: daily water-to-energy conversion factor, mm GJ-1 = m TJ-1
      ! filnam=trim(prefix)//'.d.econ.out'
      ! open(264,file=filnam,err=888,status='unknown')

    end if

    ! !----------------------------------------------------------------
    ! ! MONTHLY OUTPUT
    ! !----------------------------------------------------------------

    ! ! eq_m
    ! filnam=trim(prefix)//'.m.eq_m.out'
    ! open(211,file=filnam,err=888,status='unknown')

    ! ! ep_m
    ! filnam=trim(prefix)//'.m.ep_m.out'
    ! open(212,file=filnam,err=888,status='unknown')

    ! ! ea_m
    ! filnam=trim(prefix)//'.m.ea_m.out'
    ! open(213,file=filnam,err=888,status='unknown')

    ! ! cpa
    ! filnam=trim(prefix)//'.m.cpa.out'
    ! open(214,file=filnam,err=888,status='unknown')

    ! ! cwd
    ! filnam=trim(prefix)//'.m.cwd.out'
    ! open(215,file=filnam,err=888,status='unknown')

    ! ! qm
    ! filnam=trim(prefix)//'.m.qm.out'
    ! open(216,file=filnam,err=888,status='unknown')

    return

  888  stop 'INITIO_WATERBAL: error opening output files'

  end subroutine initio_waterbal


  subroutine initio_nc_waterbal()
    !////////////////////////////////////////////////////////////////
    ! Opens NetCDF output files.
    !----------------------------------------------------------------
    use netcdf
    use md_io_netcdf, only: init_nc_3D_time, check
    use md_interface, only: interface

    ! local variables
    character(len=256) :: prefix

    character(len=*), parameter :: TITLE = "SOFUN GP-model output, module md_waterbal (SPLASH)"
    character(len=4) :: year_char

    integer :: jpngr, doy

    write(year_char,999) interface%steering%outyear

    prefix = "./output_nc/"//trim(interface%params_siml%runname)

    if ( .not. interface%steering%spinup ) then
        !----------------------------------------------------------------
        ! Annual NetCDF output
        !----------------------------------------------------------------
        if (interface%params_siml%loutwaterbal) then
          !----------------------------------------------------------------
          ! Annual PET output file 
          !----------------------------------------------------------------
          ncoutfilnam_apet = trim(prefix)//'.'//year_char//".a.pet.nc"
          print*,'initialising ', trim(ncoutfilnam_apet), '...'
          call init_nc_3D_time( filnam  = trim(ncoutfilnam_apet), &
                          nlon     = interface%domaininfo%nlon, &
                          nlat     = interface%domaininfo%nlat, &
                          lon      = interface%domaininfo%lon, &
                          lat      = interface%domaininfo%lat, &
                          outyear  = interface%steering%outyear, &
                          outdt    = 365, &
                          outnt    = 1, &
                          varnam   = PET_NAME, &
                          varunits = "mm yr-1", &
                          longnam  = "potential evapotranspiration", &
                          title    = TITLE, &
                          globatt2_nam = "in_ppfd",   globatt2_val = trim(in_ppfd)   &
                          )

          !----------------------------------------------------------------
          ! Annual AET output file 
          !----------------------------------------------------------------
          ncoutfilnam_aaet = trim(prefix)//'.'//year_char//".a.aet.nc"
          print*,'initialising ', trim(ncoutfilnam_aaet), '...'
          call init_nc_3D_time( filnam  = trim(ncoutfilnam_aaet), &
                          nlon     = interface%domaininfo%nlon, &
                          nlat     = interface%domaininfo%nlat, &
                          lon      = interface%domaininfo%lon, &
                          lat      = interface%domaininfo%lat, &
                          outyear  = interface%steering%outyear, &
                          outdt    = 365, &
                          outnt    = 1, &
                          varnam   = AET_NAME, &
                          varunits = "mm yr-1", &
                          longnam  = "actual evapotranspiration", &
                          title    = TITLE, &
                          globatt2_nam = "in_ppfd",   globatt2_val = trim(in_ppfd)   &
                          )

          !----------------------------------------------------------------
          ! Annual ALPHA (AET/PET) output file 
          !----------------------------------------------------------------
          ncoutfilnam_aalpha = trim(prefix)//'.'//year_char//".a.alpha.nc"
          print*,'initialising ', trim(ncoutfilnam_aalpha), '...'
          call init_nc_3D_time( filnam  = trim(ncoutfilnam_aalpha), &
                          nlon     = interface%domaininfo%nlon, &
                          nlat     = interface%domaininfo%nlat, &
                          lon      = interface%domaininfo%lon, &
                          lat      = interface%domaininfo%lat, &
                          outyear  = interface%steering%outyear, &
                          outdt    = 365, &
                          outnt    = 1, &
                          varnam   = ALPHA_NAME, &
                          varunits = "", &
                          longnam  = "AET/PET, mean of daily values", &
                          title    = TITLE, &
                          globatt2_nam = "in_ppfd",   globatt2_val = trim(in_ppfd)   &
                          )
        end if


      if (       interface%steering%outyear>=interface%params_siml%daily_out_startyr &
           .and. interface%steering%outyear<=interface%params_siml%daily_out_endyr ) then      
        !----------------------------------------------------------------
        ! Daily NetCDF output
        !----------------------------------------------------------------
        if (interface%params_siml%lncoutdwaterbal) then
          !----------------------------------------------------------------
          ! Daily WCONT output file 
          !----------------------------------------------------------------
          ncoutfilnam_dwcont = trim(prefix)//'.'//year_char//".d.wcont.nc"
          print*,'initialising ', trim(ncoutfilnam_dwcont), '...'
          call init_nc_3D_time( filnam  = trim(ncoutfilnam_dwcont), &
                          nlon     = interface%domaininfo%nlon, &
                          nlat     = interface%domaininfo%nlat, &
                          lon      = interface%domaininfo%lon, &
                          lat      = interface%domaininfo%lat, &
                          outyear  = interface%steering%outyear, &
                          outdt    = interface%params_siml%outdt, &
                          outnt    = interface%params_siml%outnt, &
                          varnam   = WCONT_NAME, &
                          varunits = "mm", &
                          longnam  = "soil water content", &
                          title    = TITLE, &
                          globatt2_nam = "in_ppfd",   globatt2_val = trim(in_ppfd)   &
                          )

          ! !----------------------------------------------------------------
          ! ! Daily PPFD output file 
          ! !----------------------------------------------------------------
          ! ncoutfilnam_dppfd = trim(prefix)//'.'//year_char//".d.ppfd.nc"
          ! print*,'initialising ', trim(ncoutfilnam_dppfd), '...'
          ! call init_nc_3D_time( filnam  = trim(ncoutfilnam_dppfd), &
          !                 nlon     = interface%domaininfo%nlon, &
          !                 nlat     = interface%domaininfo%nlat, &
          !                 lon      = interface%domaininfo%lon, &
          !                 lat      = interface%domaininfo%lat, &
          !                 outyear  = interface%steering%outyear, &
          !                 outdt    = interface%params_siml%outdt, &
          !                 outnt    = interface%params_siml%outnt, &
          !                 varnam   = PPFD_NAME, &
          !                 varunits = "mol m-2 d-1", &
          !                 longnam  = "photosynthetic photon flux density", &
          !                 title    = TITLE, &
          !                 globatt2_nam = "in_ppfd",   globatt2_val = trim(in_ppfd)   &
          !                 )

          !----------------------------------------------------------------
          ! Daily PET output file 
          !----------------------------------------------------------------
          ncoutfilnam_dpet = trim(prefix)//'.'//year_char//".d.pet.nc"
          print*,'initialising ', trim(ncoutfilnam_dpet), '...'
          call init_nc_3D_time( filnam  = trim(ncoutfilnam_dpet), &
                          nlon     = interface%domaininfo%nlon, &
                          nlat     = interface%domaininfo%nlat, &
                          lon      = interface%domaininfo%lon, &
                          lat      = interface%domaininfo%lat, &
                          outyear  = interface%steering%outyear, &
                          outdt    = interface%params_siml%outdt, &
                          outnt    = interface%params_siml%outnt, &
                          varnam   = PET_NAME, &
                          varunits = "mm d-1", &
                          longnam  = "potential evapotranspiration", &
                          title    = TITLE, &
                          globatt2_nam = "in_ppfd",   globatt2_val = trim(in_ppfd)   &
                          )

          !----------------------------------------------------------------
          ! Daily AET output file 
          !----------------------------------------------------------------
          ncoutfilnam_daet = trim(prefix)//'.'//year_char//".d.aet.nc"
          print*,'initialising ', trim(ncoutfilnam_daet), '...'
          call init_nc_3D_time( filnam  = trim(ncoutfilnam_daet), &
                          nlon     = interface%domaininfo%nlon, &
                          nlat     = interface%domaininfo%nlat, &
                          lon      = interface%domaininfo%lon, &
                          lat      = interface%domaininfo%lat, &
                          outyear  = interface%steering%outyear, &
                          outdt    = interface%params_siml%outdt, &
                          outnt    = interface%params_siml%outnt, &
                          varnam   = AET_NAME, &
                          varunits = "mm d-1", &
                          longnam  = "actual evapotranspiration", &
                          title    = TITLE, &
                          globatt2_nam = "in_ppfd",   globatt2_val = trim(in_ppfd)   &
                          )        
        end if

      end if

    end if

    888  format (F12.6)
    999  format (I4.4)
    
  end subroutine initio_nc_waterbal


  subroutine initoutput_waterbal( ngridcells )
    !////////////////////////////////////////////////////////////////
    ! Initialises waterbalance-specific output variables
    ! The same subroutine is used here for initialising rolling mean variables
    !----------------------------------------------------------------
    use md_interface, only: interface

    ! arguments
    integer, intent(in) :: ngridcells

    ! ! Rolling mean variables
    ! if (interface%steering%init) allocate( rlmalpha(nlu,ngridcells) )
    ! if (interface%steering%init) rlmalpha(:,:) = 0.0

    ! Annual output variables, required for rlmalpha, irrespective of loutwaterbal
    if (interface%steering%init) then
      if (interface%steering%init) allocate( outapet(ngridcells) )
      if (interface%steering%init) allocate( outaaet(nlu,ngridcells) )
      if (interface%steering%init) allocate( outaalpha(nlu,ngridcells) )
    end if
    outapet(:)     = 0.0
    outaaet(:,:)   = 0.0
    outaalpha(:,:) = 0.0

    ! if (interface%params_siml%loutwaterbal) then
    !   if (interface%steering%init) then
    !     ...
    !   end if
    !   ...
    ! end if

    ! Daily output variables
    if (interface%params_siml%loutwaterbal) then
      if (interface%steering%init) then
        if (interface%steering%init) allocate( outdwcont (nlu,interface%params_siml%outnt,ngridcells) )  ! daily soil moisture, mm
        if (interface%steering%init) allocate( outdppfd (interface%params_siml%outnt,ngridcells)   )     ! daily PPFD, mol/m2
        if (interface%steering%init) allocate( outdpet(interface%params_siml%outnt,ngridcells)     )     ! daily potential ET, mm
        if (interface%steering%init) allocate( outdaet(nlu,interface%params_siml%outnt,ngridcells) )     ! daily actual ET, mm
        ! if (interface%steering%init) allocate( outdra (interface%params_siml%outnt,ngridcells)     )     ! daily solar irradiation, J/m2
        ! if (interface%steering%init) allocate( outdrn (interface%params_siml%outnt,ngridcells)     )     ! daily net radiation, J/m2
        ! if (interface%steering%init) allocate( outdayl(interface%params_siml%outnt,ngridcells)     )     ! daily day length, h
        ! if (interface%steering%init) allocate( outdcn (interface%params_siml%outnt,ngridcells)     )     ! daily condensation water, mm
        ! if (interface%steering%init) allocate( outdro (nlu,interface%params_siml%outnt,ngridcells) )     ! daily runoff, mm
        ! if (interface%steering%init) allocate( outdfleach (nlu,interface%params_siml%outnt,ngridcells) ) ! daily leaching fraction, (unitless)
        ! if (interface%steering%init) allocate( outdeet(interface%params_siml%outnt,ngridcells)     )     ! daily equilibrium ET, mm
        ! if (interface%steering%init) allocate( outdcpa(nlu,interface%params_siml%outnt,ngridcells) )     ! daily Cramer-Prentice-Alpha, (unitless)
        ! if (interface%steering%init) allocate( outdecon(interface%params_siml%outnt,ngridcells) )        ! daily water-to-energy conversion factor
      end if
      outdwcont(:,:,:)  = 0.0
      outdppfd(:,:)     = 0.0
      outdpet(:,:)      = 0.0
      outdaet(:,:,:)    = 0.0
      ! outdra(:,:)       = 0.0
      ! outdrn(:,:)       = 0.0
      ! outdayl(:,:)      = 0.0
      ! outdcn(:,:)       = 0.0
      ! outdro(:,:,:)     = 0.0
      ! outdfleach(:,:,:) = 0.0
      ! outdeet(:,:)      = 0.0
      ! outdcpa(:,:,:)    = 0.0
      ! outdecon(:,:)     = 0.0
    end if

  end subroutine initoutput_waterbal


  subroutine getout_daily_waterbal( jpngr, moy, doy, solar, phy )
    !////////////////////////////////////////////////////////////////
    ! Collect daily output variables
    ! so far not implemented for isotopes
    !----------------------------------------------------------------
    use md_interface, only: interface
    use md_tile, only: psoilphystype

    ! argument
    integer, intent(in)                               :: jpngr
    integer, intent(in)                               :: moy    
    integer, intent(in)                               :: doy    
    type( solartype ), intent(in)                     :: solar
    type( psoilphystype ), dimension(nlu), intent(in) :: phy

    ! local variables
    integer :: it

    it = floor( real( doy - 1 ) / real( interface%params_siml%outdt ) ) + 1

    ! Annual output variables
    if (interface%params_siml%loutwaterbal) then
      if (outenergy) then
        outapet(jpngr)    = outapet(jpngr)   + (evap(1)%pet / (evap(1)%econ * 1000.0))
        outaaet(:,jpngr)  = outaaet(:,jpngr) + (evap(:)%aet / (evap(1)%econ * 1000.0))
      else 
        outapet(jpngr)    = outapet(jpngr)   + evap(1)%pet
        outaaet(:,jpngr)  = outaaet(:,jpngr) + evap(:)%aet
      end if
      if (evap(1)%pet > 0.0) then
        outaalpha(:,jpngr)  = outaalpha(:,jpngr) + (evap(:)%aet / evap(1)%pet) / ndayyear
      else
        outaalpha(:,jpngr)  = outaalpha(:,jpngr) + 1.0 / ndayyear
      end if
    end if

    ! Daily output variables
    if (interface%params_siml%loutwaterbal) then
      outdwcont(:,it,jpngr)  = outdwcont(:,it,jpngr)  + phy(:)%wcont / real( interface%params_siml%outdt )
      outdppfd(it,jpngr)     = outdppfd(it,jpngr)     + solar%dppfd(doy) / real( interface%params_siml%outdt )
      ! outdra(it,jpngr)       = outdra(it,jpngr)       + solar%dra(doy) / real( interface%params_siml%outdt )
      ! outdayl(it,jpngr)      = outdayl(it,jpngr)      + solar%dayl(doy) / real( interface%params_siml%outdt )
      ! outdrn(it,jpngr)       = outdrn(it,jpngr)       + evap(1)%rn / real( interface%params_siml%outdt )
      ! outdeet(it,jpngr)      = outdeet(it,jpngr)      + evap(1)%eet / real( interface%params_siml%outdt )
      ! outdpet(it,jpngr)      = outdpet(it,jpngr)      + evap(1)%pet / real( interface%params_siml%outdt )
      ! outdcn(it,jpngr)       = outdcn(it,jpngr)       + evap(1)%cn / real( interface%params_siml%outdt )
      ! outdaet(:,it,jpngr)    = outdaet(:,it,jpngr)    + evap(:)%aet / real( interface%params_siml%outdt )
      ! outdcpa(:,it,jpngr)    = outdcpa(:,it,jpngr)    + evap(:)%cpa / real( interface%params_siml%outdt )
      ! outdro(:,it,jpngr)     = outdro(:,it,jpngr)     + soilphys(:)%ro / real( interface%params_siml%outdt )
      ! outdfleach(:,it,jpngr) = outdfleach(:,it,jpngr) + soilphys(:)%fleach / real( interface%params_siml%outdt )
      if (outenergy) then
        outdpet(it,jpngr)    = outdpet(it,jpngr)   + (evap(1)%pet / (evap(1)%econ * 1000.0)) / real( interface%params_siml%outdt )
        outdaet(:,it,jpngr)  = outdaet(:,it,jpngr) + (evap(:)%aet / (evap(1)%econ * 1000.0)) / real( interface%params_siml%outdt )
      else 
        outdpet(it,jpngr)    = outdpet(it,jpngr)   + evap(1)%pet / real( interface%params_siml%outdt )
        outdaet(:,it,jpngr)  = outdaet(:,it,jpngr) + evap(:)%aet / real( interface%params_siml%outdt )
      end if
      ! outdecon(it,jpngr)     = outdecon(it,jpngr)    + evap(1)%econ * 1.0e12 / real( interface%params_siml%outdt ) ! converting from m J-1 to mm GJ-1 = m TJ-1
    end if

  end subroutine getout_daily_waterbal


  subroutine get_rlm_waterbal( phy )
    !/////////////////////////////////////////////////////////////////////////
    ! Calculates the rolling mean of relevant variables
    ! This requires the full arrays (all gridcells) to be stored.
    !-------------------------------------------------------------------------
    use md_params_core, only: nlu
    use md_tile, only: psoilphystype

    ! arguments
    type( psoilphystype ), dimension(:,:), intent(inout) :: phy

    ! local variables
    integer, save :: ncalls = 0
    integer :: nyrs_uptonow
    integer :: lu

    ncalls = ncalls + 1
    nyrs_uptonow = min( ncalls, nyrs_rlmalpha )

    do lu=1,nlu
      where (outapet(:) > 0.0)
        phy(lu,:)%rlmalpha = ( phy(lu,:)%rlmalpha * (nyrs_uptonow - 1) + outaalpha(lu,:) ) / nyrs_uptonow
      elsewhere
        phy(lu,:)%rlmalpha = 1.0
      end where
    end do

  end subroutine get_rlm_waterbal


  subroutine writeout_ascii_waterbal()
    !/////////////////////////////////////////////////////////////////////////
    ! WRITE WATERBALANCE-SPECIFIC VARIABLES TO OUTPUT
    !-------------------------------------------------------------------------
    use md_params_core, only: ndayyear, nmonth
    use md_interface, only: interface

    ! Local variables
    real :: itime
    integer :: it, jpngr
    
    ! xxx implement this: sum over gridcells? single output per gridcell?
    if (maxgrid>1) stop 'writeout_ascii_waterbal: think of something ...'
    jpngr = 20000

    !-------------------------------------------------------------------------
    ! DAILY OUTPUT
    !-------------------------------------------------------------------------
    if (interface%params_siml%loutwaterbal) then

      if ( .not. interface%steering%spinup &
           .and. interface%steering%outyear>=interface%params_siml%daily_out_startyr &
           .and. interface%steering%outyear<=interface%params_siml%daily_out_endyr ) then

        ! Write daily output only during transient simulation
        do it=1,interface%params_siml%outnt

          ! Define 'itime' as a decimal number corresponding to day in the year + year
          itime = real(interface%steering%outyear) + real( it - 1 ) * interface%params_siml%outdt / real( ndayyear )

          if (nlu>1) stop 'writeout_ascii_waterbal: write out lu-area weighted sum'

          ! xxx lu-area weighted sum if nlu>0
          write(255,999) itime, outdwcont(1,it,jpngr)
          write(253,999) itime, outdppfd(it,jpngr)
          write(259,999) itime, outdpet(it,jpngr)
          write(260,999) itime, outdaet(1,it,jpngr)
          ! write(251,999) itime, outdra(it,jpngr)
          ! write(252,999) itime, outdrn(it,jpngr)
          ! write(254,999) itime, outdcn(it,jpngr)
          ! write(257,999) itime, outdro(1,it,jpngr)
          ! write(263,999) itime, outdfleach(1,it,jpngr)
          ! write(258,999) itime, outdeet(it,jpngr)
          ! write(261,999) itime, outdayl(it,jpngr)
          ! write(262,999) itime, outdcpa(1,it,jpngr)
          ! write(264,999) itime, outdecon(it,jpngr)

        end do
      end if
    end if

    return
    
    888 format (F20.8,E20.8)
    999 format (F20.8,F20.8)

  end subroutine writeout_ascii_waterbal


  subroutine writeout_nc_waterbal()
    !/////////////////////////////////////////////////////////////////////////
    ! Write NetCDF output
    !-------------------------------------------------------------------------
    use netcdf
    use md_io_netcdf, only: write_nc_2D, write_nc_3D_time, check
    use md_interface, only: interface

    if ( .not. interface%steering%spinup ) then
      !-------------------------------------------------------------------------
      ! Annual output
      !-------------------------------------------------------------------------
      if (interface%params_siml%loutwaterbal) then
        !-------------------------------------------------------------------------
        ! PET
        !-------------------------------------------------------------------------
        print*,'writing ', trim(ncoutfilnam_apet), '...'
        call write_nc_2D( trim(ncoutfilnam_apet), &
                          PET_NAME, &
                          interface%domaininfo%maxgrid, &
                          interface%domaininfo%nlon, &
                          interface%domaininfo%nlat, &
                          interface%grid(:)%ilon, &
                          interface%grid(:)%ilat, &
                          interface%grid(:)%dogridcell, &
                          outapet(:) &
                          )

        !-------------------------------------------------------------------------
        ! AET
        !-------------------------------------------------------------------------
        if (nlu>1) stop 'writeout_nc_waterbal: nlu>1. Think of something clever!'
        print*,'writing ', trim(ncoutfilnam_aaet), '...'
        call write_nc_2D( trim(ncoutfilnam_aaet), &
                          AET_NAME, &
                          interface%domaininfo%maxgrid, &
                          interface%domaininfo%nlon, &
                          interface%domaininfo%nlat, &
                          interface%grid(:)%ilon, &
                          interface%grid(:)%ilat, &
                          interface%grid(:)%dogridcell, &
                          outaaet(1,:) &
                          )

        !-------------------------------------------------------------------------
        ! ALPHA (AET/PET)
        !-------------------------------------------------------------------------
        print*,'writing ', trim(ncoutfilnam_aalpha), '...'
        call write_nc_2D( trim(ncoutfilnam_aalpha), &
                          ALPHA_NAME, &
                          interface%domaininfo%maxgrid, &
                          interface%domaininfo%nlon, &
                          interface%domaininfo%nlat, &
                          interface%grid(:)%ilon, &
                          interface%grid(:)%ilat, &
                          interface%grid(:)%dogridcell, &
                          outaalpha(1,:) &
                          )        

      end if

      if (       interface%steering%outyear>=interface%params_siml%daily_out_startyr &
           .and. interface%steering%outyear<=interface%params_siml%daily_out_endyr ) then
        !-------------------------------------------------------------------------
        ! Daily output
        !-------------------------------------------------------------------------
        if (interface%params_siml%lncoutdwaterbal) then
          !-------------------------------------------------------------------------
          ! soil water content
          !-------------------------------------------------------------------------
          print*,'writing ', trim(ncoutfilnam_dwcont), '...'
          call write_nc_3D_time( trim(ncoutfilnam_dwcont), &
                            WCONT_NAME, &
                            interface%domaininfo%maxgrid, &
                            interface%domaininfo%nlon, &
                            interface%domaininfo%nlat, &
                            interface%grid(:)%ilon, &
                            interface%grid(:)%ilat, &
                            interface%params_siml%outnt, &
                            interface%grid(:)%dogridcell, &
                            outdwcont(1,:,:) &
                            )

          ! !-------------------------------------------------------------------------
          ! ! PPFD
          ! !-------------------------------------------------------------------------
          ! print*,'writing ', trim(ncoutfilnam_dppfd), '...'
          ! call write_nc_3D_time( trim(ncoutfilnam_dppfd), &
          !                   PPFD_NAME, &
          !                   interface%domaininfo%maxgrid, &
          !                   interface%domaininfo%nlon, &
          !                   interface%domaininfo%nlat, &
          !                   interface%grid(:)%ilon, &
          !                   interface%grid(:)%ilat, &
          !                   interface%params_siml%outnt, &
          !                   interface%grid(:)%dogridcell, &
          !                   outdppfd(:,:) &
          !                   )

          !-------------------------------------------------------------------------
          ! PET
          !-------------------------------------------------------------------------
          print*,'writing ', trim(ncoutfilnam_dpet), '...'
          call write_nc_3D_time( trim(ncoutfilnam_dpet), &
                            PET_NAME, &
                            interface%domaininfo%maxgrid, &
                            interface%domaininfo%nlon, &
                            interface%domaininfo%nlat, &
                            interface%grid(:)%ilon, &
                            interface%grid(:)%ilat, &
                            interface%params_siml%outnt, &
                            interface%grid(:)%dogridcell, &
                            outdpet(:,:) &
                            )

          !-------------------------------------------------------------------------
          ! AET
          !-------------------------------------------------------------------------
          if (nlu>1) stop 'writeout_nc_waterbal: nlu>1. Think of something clever!'
          print*,'writing ', trim(ncoutfilnam_daet), '...'
          call write_nc_3D_time( trim(ncoutfilnam_daet), &
                            AET_NAME, &
                            interface%domaininfo%maxgrid, &
                            interface%domaininfo%nlon, &
                            interface%domaininfo%nlat, &
                            interface%grid(:)%ilon, &
                            interface%grid(:)%ilat, &
                            interface%params_siml%outnt, &
                            interface%grid(:)%dogridcell, &
                            outdaet(1,:,:) &
                            )

        end if

      end if

    end if

  end subroutine writeout_nc_waterbal

end module md_waterbal
