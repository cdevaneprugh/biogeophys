module SaturatedExcessRunoffMod

  !-----------------------------------------------------------------------
  ! !DESCRIPTION:
  ! Type and associated routines for calculating surface runoff due to saturated surface
  !
  ! This also includes calculations of fsat (fraction of each column that is saturated)
  !
  ! !USES:
#include "shr_assert.h"
  use shr_kind_mod , only : r8 => shr_kind_r8
  use shr_log_mod  , only : errMsg => shr_log_errMsg
  use decompMod    , only : bounds_type
  use abortutils   , only : endrun
  use clm_varctl   , only : iulog, use_vichydro, crop_fsat_equals_zero, hillslope_fsat_equals_zero
  use clm_varcon   , only : spval, ispval
  use LandunitType , only : landunit_type
  use landunit_varcon  , only : istcrop
  use ColumnType   , only : column_type
  use SoilHydrologyType, only : soilhydrology_type
  !use SoilHydrologyMod, only : h2osfc ! CAUSING CIRCULAR DEPENDENCY
  use WaterStateBulkType , only : waterstatebulk_type ! Need to use to access h2osfc
  use SoilStateType, only : soilstate_type
  use WaterFluxBulkType, only : waterfluxbulk_type

  implicit none
  save
  private

  ! !PUBLIC TYPES:

  type, public :: saturated_excess_runoff_type
     private
     ! Public data members
     ! Note: these should be treated as read-only by other modules
     real(r8), pointer, public :: fsat_col(:) ! fractional area with water table at surface

     ! Private data members
     integer :: fsat_method
     real(r8), pointer :: fcov_col(:) ! fractional impermeable area
   contains
     ! Public routines
     procedure, public :: Init

     procedure, public :: SaturatedExcessRunoff ! Calculate surface runoff due to saturated surface

     ! Private routines
     procedure, private :: InitAllocate
     procedure, private :: InitHistory
     procedure, private :: InitCold

     procedure, private, nopass :: ComputeFsatTopmodel
     procedure, private, nopass :: ComputeFsatVic
  end type saturated_excess_runoff_type
  public :: readParams

  type, private :: params_type
     real(r8) :: fff  ! Decay factor for fractional saturated area (1/m)
  end type params_type
  type(params_type), private ::  params_inst

  ! !PRIVATE DATA MEMBERS:

  integer, parameter :: FSAT_METHOD_TOPMODEL = 1
  integer, parameter :: FSAT_METHOD_VIC      = 2

  character(len=*), parameter, private :: sourcefile = &
       __FILE__

contains

  ! ========================================================================
  ! Infrastructure routines
  ! ========================================================================

  !-----------------------------------------------------------------------
  subroutine Init(this, bounds)
    !
    ! !DESCRIPTION:
    ! Initialize this saturated_excess_runoff_type object
    !
    ! !ARGUMENTS:
    class(saturated_excess_runoff_type), intent(inout) :: this
    type(bounds_type), intent(in) :: bounds
    !
    ! !LOCAL VARIABLES:

    character(len=*), parameter :: subname = 'Init'
    !-----------------------------------------------------------------------

    call this%InitAllocate(bounds)
    call this%InitHistory(bounds)
    call this%InitCold(bounds)

  end subroutine Init

  !-----------------------------------------------------------------------
  subroutine InitAllocate(this, bounds)
    !
    ! !DESCRIPTION:
    ! Allocate memory for this saturated_excess_runoff_type object
    !
    ! !USES:
    use shr_infnan_mod , only : nan => shr_infnan_nan, assignment(=)
    !
    ! !ARGUMENTS:
    class(saturated_excess_runoff_type), intent(inout) :: this
    type(bounds_type), intent(in) :: bounds
    !
    ! !LOCAL VARIABLES:
    integer :: begc, endc

    character(len=*), parameter :: subname = 'InitAllocate'
    !-----------------------------------------------------------------------

    begc = bounds%begc; endc= bounds%endc

    allocate(this%fsat_col(begc:endc))                 ; this%fsat_col(:)                 = nan
    allocate(this%fcov_col(begc:endc))                 ; this%fcov_col(:)                 = nan   

  end subroutine InitAllocate

  !-----------------------------------------------------------------------
  subroutine InitHistory(this, bounds)
    !
    ! !DESCRIPTION:
    ! Initialize saturated_excess_runoff_type history variables
    !
    ! !USES:
    use histFileMod , only : hist_addfld1d
    !
    ! !ARGUMENTS:
    class(saturated_excess_runoff_type), intent(inout) :: this
    type(bounds_type), intent(in) :: bounds
    !
    ! !LOCAL VARIABLES:
    integer :: begc, endc

    character(len=*), parameter :: subname = 'InitHistory'
    !-----------------------------------------------------------------------

    begc = bounds%begc; endc= bounds%endc

    this%fcov_col(begc:endc) = spval
    call hist_addfld1d (fname='FCOV',  units='unitless',  &
         avgflag='A', long_name='fractional impermeable area', &
         ptr_col=this%fcov_col, l2g_scale_type='veg')

    this%fsat_col(begc:endc) = spval
    call hist_addfld1d (fname='FSAT',  units='unitless',  &
         avgflag='A', long_name='fractional area with water table at surface', &
         ptr_col=this%fsat_col, l2g_scale_type='veg')

  end subroutine InitHistory

  !-----------------------------------------------------------------------
  subroutine InitCold(this, bounds)
    !
    ! !DESCRIPTION:
    ! Perform cold-start initialization for saturated_excess_runoff_type
    !
    ! !ARGUMENTS:
    class(saturated_excess_runoff_type), intent(inout) :: this
    type(bounds_type), intent(in) :: bounds
    !
    ! !LOCAL VARIABLES:

    character(len=*), parameter :: subname = 'InitCold'
    !-----------------------------------------------------------------------

    ! TODO(wjs, 2017-07-12) We'll read fsat_method from namelist.
    if (use_vichydro) then
       this%fsat_method = FSAT_METHOD_VIC
    else
       this%fsat_method = FSAT_METHOD_TOPMODEL
    end if

  end subroutine InitCold

  !-----------------------------------------------------------------------
  subroutine readParams( ncid )
    !
    ! !USES:
    use ncdio_pio, only: file_desc_t
    use paramUtilMod, only: readNcdioScalar
    !
    ! !ARGUMENTS:
    implicit none
    type(file_desc_t),intent(inout) :: ncid   ! pio netCDF file id
    !
    ! !LOCAL VARIABLES:
    character(len=*), parameter :: subname = 'readParams_SaturatedExcessRunoff'
    !--------------------------------------------------------------------

    ! Decay factor for fractional saturated area (1/m)
    call readNcdioScalar(ncid, 'fff', subname, params_inst%fff)

  end subroutine readParams

  ! ========================================================================
  ! Science routines
  ! ========================================================================

  !-----------------------------------------------------------------------
  subroutine SaturatedExcessRunoff (this, bounds, num_hydrologyc, filter_hydrologyc, &
       lun, col, soilhydrology_inst, soilstate_inst, waterfluxbulk_inst, waterstatebulk_inst) ! Pass waterstatebulk_inst
    !
    ! !DESCRIPTION:
    ! Calculate surface runoff due to saturated surface
    !
    ! Sets this%fsat_col and waterfluxbulk_inst%qflx_sat_excess_surf_col
    !
    ! !ARGUMENTS:
    class(saturated_excess_runoff_type), intent(inout) :: this
    type(bounds_type)        , intent(in)    :: bounds               
    integer                  , intent(in)    :: num_hydrologyc       ! number of column soil points in column filter
    integer                  , intent(in)    :: filter_hydrologyc(:) ! column filter for soil points
    type(landunit_type)      , intent(in)    :: lun
    type(column_type)        , intent(in)    :: col
    type(soilhydrology_type) , intent(inout) :: soilhydrology_inst
    type(soilstate_type)     , intent(in)    :: soilstate_inst
    type(waterfluxbulk_type) , intent(inout) :: waterfluxbulk_inst
    type(waterstatebulk_type), intent(in)    :: waterstatebulk_inst  ! Declare variable, specify type, and intent
    !
    ! !LOCAL VARIABLES:
    integer  :: fc, c, l

    character(len=*), parameter :: subname = 'SaturatedExcessRunoff'
    !-----------------------------------------------------------------------

    associate(                                                        & 
         fcov                   =>    this%fcov_col                          , & ! Output: [real(r8) (:)   ]  fractional impermeable area
         fsat                   =>    this%fsat_col                          , & ! Output: [real(r8) (:)   ]  fractional area with water table at surface

         snl                    =>    col%snl                                , & ! Input:  [integer  (:)   ]  minus number of snow layers

         qflx_sat_excess_surf   =>    waterfluxbulk_inst%qflx_sat_excess_surf_col, & ! Output: [real(r8) (:)   ]  surface runoff due to saturated surface (mm H2O /s)
         qflx_floodc            =>    waterfluxbulk_inst%qflx_floodc_col         , & ! Input:  [real(r8) (:)   ]  column flux of flood water from RTM
         qflx_rain_plus_snomelt => waterfluxbulk_inst%qflx_rain_plus_snomelt_col   & ! Input: [real(r8) (:)   ] rain plus snow melt falling on the soil (mm/s)

         )

    ! ------------------------------------------------------------------------
    ! Compute fsat
    ! ------------------------------------------------------------------------

    select case (this%fsat_method)
    case (FSAT_METHOD_TOPMODEL)
       call this%ComputeFsatTopmodel(bounds, num_hydrologyc, filter_hydrologyc, &
            soilhydrology_inst, soilstate_inst, waterstatebulk_inst, &
            fsat = fsat(bounds%begc:bounds%endc))
    case (FSAT_METHOD_VIC)
       call this%ComputeFsatVic(bounds, num_hydrologyc, filter_hydrologyc, &
            soilhydrology_inst, &
            fsat = fsat(bounds%begc:bounds%endc))
    case default
       write(iulog,*) subname//' ERROR: Unrecognized fsat_method: ', this%fsat_method
       call endrun(subname//' ERROR: Unrecognized fsat_method')
    end select

    ! ------------------------------------------------------------------------
    ! Set fsat to zero for crop columns
    ! ------------------------------------------------------------------------
    if (crop_fsat_equals_zero) then
       do fc = 1, num_hydrologyc
          c = filter_hydrologyc(fc)
          l = col%landunit(c)
          if(lun%itype(l) == istcrop) fsat(c) = 0._r8
       end do
    endif
    ! ------------------------------------------------------------------------
    ! Set fsat to zero for upland hillslope columns
    ! ------------------------------------------------------------------------
    if (hillslope_fsat_equals_zero) then
      do fc = 1, num_hydrologyc
         c = filter_hydrologyc(fc)
         if(col%is_hillslope_column(c) .and. col%active(c)) then
            ! Set fsat to zero for upland columns
            if (col%cold(c) /= ispval) fsat(c) = 0._r8
         endif
      end do
   endif
    ! ------------------------------------------------------------------------
    ! Compute qflx_sat_excess_surf
    !
    ! assume qinmax (maximum infiltration rate) is large relative to
    ! qflx_rain_plus_snomelt in control
    ! ------------------------------------------------------------------------
    
    do fc = 1, num_hydrologyc
       c = filter_hydrologyc(fc)
       ! only send fast runoff directly to streams
       qflx_sat_excess_surf(c) = fsat(c) * qflx_rain_plus_snomelt(c)
       
       ! Set fcov just to have it on the history file
       fcov(c) = fsat(c)
    end do

    ! ------------------------------------------------------------------------
    ! For urban columns, send flood water flux to runoff
    ! ------------------------------------------------------------------------

    do fc = 1, num_hydrologyc
       c = filter_hydrologyc(fc)
       if (col%urbpoi(c)) then
          ! send flood water flux to runoff for all urban columns
          qflx_sat_excess_surf(c) = qflx_sat_excess_surf(c) + qflx_floodc(c)
       end if
    end do

    end associate

  end subroutine SaturatedExcessRunoff

  !-----------------------------------------------------------------------
  subroutine ComputeFsatTopmodel(bounds, num_hydrologyc, filter_hydrologyc, &
       soilhydrology_inst, soilstate_inst, waterstatebulk_inst, fsat) ! pass waterstatebulk_inst to subroutine
    !
    ! !DESCRIPTION:
    ! Compute fsat using the TOPModel-based parameterization
    !
    ! This is the CLM default parameterization
    !
    ! !ARGUMENTS:
    type(bounds_type), intent(in) :: bounds
    integer, intent(in) :: num_hydrologyc       ! number of column soil points in column filter
    integer, intent(in) :: filter_hydrologyc(:) ! column filter for soil points
    type(soilhydrology_type) , intent(in) :: soilhydrology_inst
    type(soilstate_type), intent(in) :: soilstate_inst
    real(r8), intent(inout) :: fsat( bounds%begc: ) ! fractional area with water table at surface
    type(waterstatebulk_type), intent(in) :: waterstatebulk_inst ! tells the compiler we're passing the full water state structure in
    !
    ! !LOCAL VARIABLES:
    integer  :: fc, c
    real(r8) :: fff ! decay factor (m-1)
    real(r8) :: humhol_ht

    character(len=*), parameter :: subname = 'ComputeFsatTopmodel'
    !-----------------------------------------------------------------------

    SHR_ASSERT_ALL_FL((ubound(fsat) == (/bounds%endc/)), sourcefile, __LINE__)

    associate( &
         frost_table      =>    soilhydrology_inst%frost_table_col  , & ! Input:  [real(r8) (:)   ]  frost table depth (m)
         zwt              =>    soilhydrology_inst%zwt_col          , & ! Input:  [real(r8) (:)   ]  water table depth (m)
         zwt_perched      =>    soilhydrology_inst%zwt_perched_col  , & ! Input:  [real(r8) (:)   ]  perched water table depth (m)
         h2osfc           =>    waterstatebulk_inst%h2osfc_col      , & ! Input:  [real(r8) (:)   ]  surface water (mm)
         wtfact           =>    soilstate_inst%wtfact_col             ) ! Input:  [real(r8) (:)   ]  maximum saturated fraction for a gridcell


    do fc = 1, num_hydrologyc
       c = filter_hydrologyc(fc)

    !----------------------------------------------------------------------
    ! HUM_HOL modified loop start
    !----------------------------------------------------------------------

#ifdef HUM_HOL
       humhol_ht = 0.15_r8

       if (frost_table(c) > zwt(c)) then
          if (c .eq. 1) then
             fsat(c) = 1.0 * exp(-3.0_r8 / humhol_ht * (zwt(c))) 
          elseif (c .eq. 2) then
             fsat(c) = min(1.0 * exp(-3.0_r8 / humhol_ht * (zwt(c) - h2osfc(c) / 1000.0 + humhol_ht / 2.0_r8)), 1._r8)
          end if

       elseif (frost_table(c) > zwt_perched(c)) then
          if (c .eq. 1) then
             fsat(c) = 1.0 * exp(-3.0_r8 / humhol_ht * (zwt_perched(c)))
          elseif (c .eq. 2) then
             fsat(c) = min(1.0 * exp(-3.0_r8 / humhol_ht * (zwt_perched(c) - h2osfc(c) / 1000.0 + humhol_ht / 2.0_r8)), 1._r8)
          end if

       else
          if (c .eq. 1) then
             fsat(c) = 1.0 * exp(-3.0_r8 / humhol_ht * (zwt(c)))
          elseif (c .eq. 2) then
             fsat(c) = min(1.0 * exp(-3.0_r8 / humhol_ht * (zwt(c) - h2osfc(c) / 1000.0 + humhol_ht / 2.0_r8)), 1._r8)
          end if

       end if

    !----------------------------------------------------------------------
    ! HUM_HOL modified loop end
    !----------------------------------------------------------------------

#else
       if (frost_table(c) > zwt_perched(c) .and. frost_table(c) <= zwt(c)) then
          ! use perched water table to determine fsat (if present)
          fsat(c) = wtfact(c) * exp(-0.5_r8 * params_inst%fff * zwt_perched(c))
       else
          fsat(c) = wtfact(c) * exp(-0.5_r8 * params_inst%fff * zwt(c))
       end if

#endif
    
    end do


    end associate

  end subroutine ComputeFsatTopmodel

  !-----------------------------------------------------------------------
  subroutine ComputeFsatVic(bounds, num_hydrologyc, filter_hydrologyc, &
       soilhydrology_inst, fsat)
    !
    ! !DESCRIPTION:
    ! Compute fsat using the VIC-based parameterization
    !
    ! Citation: Wood et al. 1992, "A land-surface hydrology parameterization with subgrid
    ! variability for general circulation models", JGR 97(D3), 2717-2728.
    !
    ! This implementation gives a first-order approximation to saturated excess runoff.
    ! For now we're not including the more exact analytical solution, or even a better
    ! numerical approximation.
    !
    ! !ARGUMENTS:
    type(bounds_type), intent(in) :: bounds
    integer, intent(in) :: num_hydrologyc       ! number of column soil points in column filter
    integer, intent(in) :: filter_hydrologyc(:) ! column filter for soil points
    type(soilhydrology_type) , intent(in) :: soilhydrology_inst
    real(r8), intent(inout) :: fsat( bounds%begc: ) ! fractional area with water table at surface
    !
    ! !LOCAL VARIABLES:
    integer :: fc, c
    real(r8) :: ex(bounds%begc:bounds%endc) ! exponent

    character(len=*), parameter :: subname = 'ComputeFsatVic'
    !-----------------------------------------------------------------------

    SHR_ASSERT_ALL_FL((ubound(fsat) == (/bounds%endc/)), sourcefile, __LINE__)

    associate( &
         b_infil          =>    soilhydrology_inst%b_infil_col      , & ! Input:  [real(r8) (:)   ]  VIC b infiltration parameter
         top_max_moist    =>    soilhydrology_inst%top_max_moist_col, & ! Input:  [real(r8) (:)   ]  maximum soil moisture in top VIC layers
         top_moist_limited =>   soilhydrology_inst%top_moist_limited_col & ! Input:  [real(r8) (:) ]  soil moisture in top layers, limited to no greater than top_max_moist
         )

    do fc = 1, num_hydrologyc
       c = filter_hydrologyc(fc)
       ex(c) = b_infil(c) / (1._r8 + b_infil(c))
       ! fsat is equivalent to A in VIC papers
       fsat(c) = 1._r8 - (1._r8 - top_moist_limited(c) / top_max_moist(c))**ex(c)
    end do

    end associate

  end subroutine ComputeFsatVic


end module SaturatedExcessRunoffMod
