module lnd_comp_nuopc

  !----------------------------------------------------------------------------
  ! This is the NUOPC cap for XLND
  !----------------------------------------------------------------------------
  use ESMF
  use NUOPC                 , only : NUOPC_CompDerive, NUOPC_CompSetEntryPoint, NUOPC_CompSpecialize
  use NUOPC                 , only : NUOPC_CompAttributeGet, NUOPC_Advertise
  use NUOPC_Model           , only : model_routine_SS        => SetServices
  use NUOPC_Model           , only : model_label_Advance     => label_Advance
  use NUOPC_Model           , only : model_label_SetRunClock => label_SetRunClock
  use NUOPC_Model           , only : model_label_Finalize    => label_Finalize
  use NUOPC_Model           , only : NUOPC_ModelGet
  use med_constants_mod     , only : IN, R8, I8, CXX, CL, CS
  use med_constants_mod     , only : shr_log_Unit
  use med_constants_mod     , only : shr_file_getlogunit, shr_file_setlogunit
  use med_constants_mod     , only : shr_file_getloglevel, shr_file_setloglevel
  use med_constants_mod     , only : shr_file_setIO, shr_file_getUnit
  use shr_nuopc_scalars_mod , only : flds_scalar_name
  use shr_nuopc_scalars_mod , only : flds_scalar_num
  use shr_nuopc_scalars_mod , only : flds_scalar_index_nx
  use shr_nuopc_scalars_mod , only : flds_scalar_index_ny
  use shr_nuopc_methods_mod , only : shr_nuopc_methods_Clock_TimePrint
  use shr_nuopc_methods_mod , only : shr_nuopc_methods_State_SetScalar
  use shr_nuopc_methods_mod , only : shr_nuopc_methods_State_Diagnose
  use shr_nuopc_methods_mod , only : shr_nuopc_methods_ChkErr
  use shr_nuopc_grid_mod    , only : shr_nuopc_grid_Meshinit
  use dead_nuopc_mod        , only : dead_grid_lat, dead_grid_lon, dead_grid_index
  use dead_nuopc_mod        , only : dead_init_nuopc, dead_run_nuopc, dead_final_nuopc
  use dead_nuopc_mod        , only : fld_list_add, fld_list_realize, fldsMax, fld_list_type
  use dead_nuopc_mod        , only : state_getimport, state_setexport
  use dead_nuopc_mod        , only : ModelInitPhase, ModelSetRunClock, Print_FieldExchInfo
  use med_constants_mod, only : dbug=>med_constants_dbug_flag

  implicit none
  private ! except

  public :: SetServices

  !--------------------------------------------------------------------------
  ! Private module data
  !--------------------------------------------------------------------------

  integer                    :: fldsToLnd_num = 0
  integer                    :: fldsFrLnd_num = 0
  type (fld_list_type)       :: fldsToLnd(fldsMax)
  type (fld_list_type)       :: fldsFrLnd(fldsMax)

  real(r8), pointer          :: gbuf(:,:)            ! model info
  real(r8), pointer          :: lat(:)
  real(r8), pointer          :: lon(:)
  integer , allocatable      :: gindex(:)
  real(r8), allocatable      :: x2d(:,:)
  real(r8), allocatable      :: d2x(:,:)
  character(CXX)             :: flds_l2x = ''
  character(CXX)             :: flds_x2l = ''
  integer                    :: nxg                  ! global dim i-direction
  integer                    :: nyg                  ! global dim j-direction
  integer                    :: mpicom               ! mpi communicator
  integer                    :: my_task              ! my task in mpi communicator mpicom
  integer                    :: inst_index           ! number of current instance (ie. 1)
  character(len=16)          :: inst_name            ! fullname of current instance (ie. "lnd_0001")
  character(len=16)          :: inst_suffix = ""     ! char string associated with instance (ie. "_0001" or "")
  integer                    :: logunit              ! logging unit number
  integer    ,parameter      :: master_task=0        ! task number of master task
  logical :: mastertask
  character(len=*),parameter :: grid_option = "mesh" ! grid_de, grid_arb, grid_reg, mesh
  integer                    :: dbrc
  character(*),parameter     :: modName =  "(xlnd_comp_nuopc)"
  character(*),parameter     :: u_FILE_u = &
       __FILE__

!===============================================================================
contains
!===============================================================================

  subroutine SetServices(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc
    character(len=*),parameter  :: subname=trim(modName)//':(SetServices) '

    rc = ESMF_SUCCESS
    if (dbug > 5) call ESMF_LogWrite(subname//' called', ESMF_LOGMSG_INFO, rc=dbrc)

    ! the NUOPC gcomp component will register the generic methods
    call NUOPC_CompDerive(gcomp, model_routine_SS, rc=rc)
    if (shr_nuopc_methods_ChkErr(rc,__LINE__,u_FILE_u)) return

    ! switching to IPD versions
    call ESMF_GridCompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
         userRoutine=ModelInitPhase, phase=0, rc=rc)
    if (shr_nuopc_methods_ChkErr(rc,__LINE__,u_FILE_u)) return

    ! set entry point for methods that require specific implementation
    call NUOPC_CompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
      phaseLabelList=(/"IPDv01p1"/), userRoutine=InitializeAdvertise, rc=rc)
    if (shr_nuopc_methods_ChkErr(rc,__LINE__,u_FILE_u)) return

    call NUOPC_CompSetEntryPoint(gcomp, ESMF_METHOD_INITIALIZE, &
      phaseLabelList=(/"IPDv01p3"/), userRoutine=InitializeRealize, rc=rc)
    if (shr_nuopc_methods_ChkErr(rc,__LINE__,u_FILE_u)) return

    ! attach specializing method(s)
    call NUOPC_CompSpecialize(gcomp, specLabel=model_label_Advance, specRoutine=ModelAdvance, rc=rc)
    if (shr_nuopc_methods_ChkErr(rc,__LINE__,u_FILE_u)) return

    call ESMF_MethodRemove(gcomp, label=model_label_SetRunClock, rc=rc)
    if (shr_nuopc_methods_ChkErr(rc,__LINE__,u_FILE_u)) return
    call NUOPC_CompSpecialize(gcomp, specLabel=model_label_SetRunClock, specRoutine=ModelSetRunClock, rc=rc)
    if (shr_nuopc_methods_ChkErr(rc,__LINE__,u_FILE_u)) return

    call NUOPC_CompSpecialize(gcomp, specLabel=model_label_Finalize, specRoutine=ModelFinalize, rc=rc)
    if (shr_nuopc_methods_ChkErr(rc,__LINE__,u_FILE_u)) return

    if (dbug > 5) call ESMF_LogWrite(subname//' done', ESMF_LOGMSG_INFO, rc=dbrc)

  end subroutine SetServices

  !===============================================================================

  subroutine InitializeAdvertise(gcomp, importState, exportState, clock, rc)
    use shr_nuopc_utils_mod, only : shr_nuopc_set_component_logging
    use shr_nuopc_utils_mod, only : shr_nuopc_get_component_instance

    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc

    ! local variables
    type(ESMF_VM)      :: vm
    integer            :: lmpicom
    character(CL)      :: cvalue
    character(CS)      :: stdname
    integer            :: n
    integer            :: lsize       ! local array size
    integer            :: ierr        ! error code
    integer            :: shrlogunit  ! original log unit
    integer            :: shrloglev   ! original log level
    logical            :: isPresent
    character(len=512) :: diro
    character(len=512) :: logfile
    character(len=*),parameter :: subname=trim(modName)//':(InitializeAdvertise) '
    !-------------------------------------------------------------------------------

    rc = ESMF_SUCCESS
    if (dbug > 5) call ESMF_LogWrite(subname//' called', ESMF_LOGMSG_INFO, rc=dbrc)

    !----------------------------------------------------------------------------
    ! generate local mpi comm
    !----------------------------------------------------------------------------

    call ESMF_GridCompGet(gcomp, vm=vm, rc=rc)
    if (shr_nuopc_methods_ChkErr(rc,__LINE__,u_FILE_u)) return

    call ESMF_VMGet(vm, mpiCommunicator=lmpicom, localpet=my_task, rc=rc)
    if (shr_nuopc_methods_ChkErr(rc,__LINE__,u_FILE_u)) return

    call mpi_comm_dup(lmpicom, mpicom, ierr)
    mastertask = my_task == master_task

    !----------------------------------------------------------------------------
    ! determine instance information
    !----------------------------------------------------------------------------

    call shr_nuopc_get_component_instance(gcomp, inst_suffix, inst_index)
    inst_name = "LND"//trim(inst_suffix)

    !----------------------------------------------------------------------------
    ! set logunit and set shr logging to my log file
    !----------------------------------------------------------------------------

    call shr_nuopc_set_component_logging(gcomp, my_task==master_task, logunit, shrlogunit, shrloglev)

    !----------------------------------------------------------------------------
    ! Initialize xlnd
    !----------------------------------------------------------------------------

    call dead_init_nuopc('lnd', inst_suffix, logunit, lsize, gbuf, nxg, nyg)

    allocate(gindex(lsize))
    allocate(lon(lsize))
    allocate(lat(lsize))

    gindex(:) = gbuf(:,dead_grid_index)
    lat(:)    = gbuf(:,dead_grid_lat)
    lon(:)    = gbuf(:,dead_grid_lon)

    !--------------------------------
    ! advertise import and export fields
    !--------------------------------

    if (nxg /= 0 .and. nyg /= 0) then

       call fld_list_add(fldsFrLnd_num, fldsFrlnd, trim(flds_scalar_name))
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Sl_lfrin'      , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Sl_t'          , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Sl_tref'       , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Sl_qref'       , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Sl_avsdr'      , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Sl_anidr'      , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Sl_avsdf'      , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Sl_anidf'      , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Sl_snowh'      , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Sl_u10'        , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Sl_fv'         , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Sl_ram1'       , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Flrl_rofsur'   , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Flrl_rofgwl'   , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Flrl_rofsub'   , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Flrl_rofi'     , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Flrl_irrig'    , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Fall_taux'     , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Fall_tauy'     , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Fall_lat'      , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Fall_sen'      , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Fall_lwup'     , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Fall_evap'     , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Fall_swnet'    , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Fall_flxdst1'  , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Fall_flxdst2'  , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Fall_flxdst3'  , flds_concat=flds_l2x)
       call fld_list_add(fldsFrLnd_num, fldsFrlnd, 'Fall_flxdst4'  , flds_concat=flds_l2x)

       do n = 1,fldsFrLnd_num
          write(logunit,*)'Advertising From Xlnd ',trim(fldsFrLnd(n)%stdname)
          call NUOPC_Advertise(exportState, standardName=fldsFrLnd(n)%stdname, &
               TransferOfferGeomObject='will provide', rc=rc)
          if (shr_nuopc_methods_ChkErr(rc,__LINE__,u_FILE_u)) return
       enddo

       call fld_list_add(fldsToLnd_num, fldsToLnd, trim(flds_scalar_name))
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Sa_z'         , flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Sa_topo'      , flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Sa_u'         , flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Sa_v'         , flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Sa_ptem'      , flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Sa_pbot'      , flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Sa_tbot'      , flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Sa_shum'      , flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Flrr_volr'    , flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Flrr_volrmch' , flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Faxa_lwdn'    , flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Faxa_rainc'   , flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Faxa_rainl'   , flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Faxa_snowc'   , flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Faxa_snowl'   , flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Faxa_swndr'   , flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Faxa_swvdr'   , flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Faxa_swndf'   , flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Faxa_swvdf'   , flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Faxa_bcphidry', flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Faxa_bcphodry', flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Faxa_bcphiwet', flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Faxa_ocphidry', flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Faxa_ocphodry', flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Faxa_ocphiwet', flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Faxa_dstdry1' , flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Faxa_dstdry2' , flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Faxa_dstdry3' , flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Faxa_dstdry4' , flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Faxa_dstwet1' , flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Faxa_dstwet2' , flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Faxa_dstwet3' , flds_concat=flds_x2l)
       call fld_list_add(fldsToLnd_num, fldsToLnd, 'Faxa_dstwet4' , flds_concat=flds_x2l)

       do n = 1,fldsToLnd_num
          write(logunit,*)'Advertising To Xlnd',trim(fldsToLnd(n)%stdname)
          call NUOPC_Advertise(importState, standardName=fldsToLnd(n)%stdname, &
               TransferOfferGeomObject='will provide', rc=rc)
          if (shr_nuopc_methods_ChkErr(rc,__LINE__,u_FILE_u)) return
       enddo

       allocate(d2x(FldsFrLnd_num,lsize)); d2x(:,:)  = 0._r8
       allocate(x2d(FldsToLnd_num,lsize)); x2d(:,:)  = 0._r8
    end if


    !----------------------------------------------------------------------------
    ! Reset shr logging to original values
    !----------------------------------------------------------------------------

    call shr_file_setLogLevel(shrloglev)
    call shr_file_setLogUnit (shrlogunit)

  end subroutine InitializeAdvertise

  !===============================================================================

  subroutine InitializeRealize(gcomp, importState, exportState, clock, rc)
    type(ESMF_GridComp)  :: gcomp
    type(ESMF_State)     :: importState, exportState
    type(ESMF_Clock)     :: clock
    integer, intent(out) :: rc

    ! local variables
    character(ESMF_MAXSTR) :: convCIM, purpComp
    type(ESMF_Mesh)        :: Emesh
    integer                :: shrlogunit                ! original log unit
    integer                :: shrloglev                 ! original log level
    type(ESMF_VM)          :: vm
    integer                :: n
    logical                :: connected                 ! is field connected?
    character(len=*),parameter :: subname=trim(modName)//':(InitializeRealize) '
    !-------------------------------------------------------------------------------

    rc = ESMF_SUCCESS
    if (dbug > 5) call ESMF_LogWrite(subname//' called', ESMF_LOGMSG_INFO, rc=dbrc)

    !----------------------------------------------------------------------------
    ! Reset shr logging to my log file
    !----------------------------------------------------------------------------

    call shr_file_getLogUnit (shrlogunit)
    call shr_file_getLogLevel(shrloglev)
    call shr_file_setLogLevel(max(shrloglev,1))
    call shr_file_setLogUnit (logUnit)

    !--------------------------------
    ! generate the mesh
    !--------------------------------

    call shr_nuopc_grid_MeshInit(gcomp, nxg, nyg, mpicom, gindex, lon, lat, Emesh, rc)
    if (shr_nuopc_methods_ChkErr(rc,__LINE__,u_FILE_u)) return

    !--------------------------------
    ! realize the actively coupled fields, now that a mesh is established
    ! NUOPC_Realize "realizes" a previously advertised field in the importState and exportState
    ! by replacing the advertised fields with the newly created fields of the same name.
    !--------------------------------

    call fld_list_realize( &
         state=ExportState, &
         fldlist=fldsFrLnd, &
         numflds=fldsFrLnd_num, &
         flds_scalar_name=flds_scalar_name, &
         flds_scalar_num=flds_scalar_num, &
         tag=subname//':dlndExport',&
         mesh=Emesh, rc=rc)
    if (shr_nuopc_methods_ChkErr(rc,__LINE__,u_FILE_u)) return

    call fld_list_realize( &
         state=importState, &
         fldList=fldsToLnd, &
         numflds=fldsToLnd_num, &
         flds_scalar_name=flds_scalar_name, &
         flds_scalar_num=flds_scalar_num, &
         tag=subname//':dlndImport',&
         mesh=Emesh, rc=rc)
    if (shr_nuopc_methods_ChkErr(rc,__LINE__,u_FILE_u)) return

    !--------------------------------
    ! Pack export state
    ! Copy from d2x to exportState
    ! Set the coupling scalars
    !--------------------------------

    do n = 1, FldsFrLnd_num
       if (fldsFrLnd(n)%stdname /= flds_scalar_name) then
          call state_setexport(exportState, trim(fldsFrLnd(n)%stdname), d2x(n,:), rc=rc)
          if (shr_nuopc_methods_ChkErr(rc,__LINE__,u_FILE_u)) return
       end if
    end do

    call shr_nuopc_methods_State_SetScalar(dble(nxg),flds_scalar_index_nx, exportState, mpicom, &
         flds_scalar_name, flds_scalar_num, rc)
    if (shr_nuopc_methods_ChkErr(rc,__LINE__,u_FILE_u)) return

    call shr_nuopc_methods_State_SetScalar(dble(nyg),flds_scalar_index_ny, exportState, mpicom, &
         flds_scalar_name, flds_scalar_num, rc)
    if (shr_nuopc_methods_ChkErr(rc,__LINE__,u_FILE_u)) return

    !--------------------------------
    ! diagnostics
    !--------------------------------

    if (dbug > 1) then
       if (my_task == master_task) then
          call Print_FieldExchInfo(values=d2x, logunit=logunit, &
               fldlist=fldsFrLnd, nflds=fldsFrLnd_num, istr="InitializeRealize: lnd->mediator")
       end if
       call shr_nuopc_methods_State_diagnose(exportState,subname//':ES',rc=rc)
       if (shr_nuopc_methods_ChkErr(rc,__LINE__,u_FILE_u)) return
    endif

#ifdef USE_ESMF_METADATA
    convCIM  = "CIM"
    purpComp = "Model Component Simulation Description"
    call ESMF_AttributeAdd(comp,  convention=convCIM, purpose=purpComp, rc=rc)
    call ESMF_AttributeSet(comp, "ShortName", "XLND", convention=convCIM, purpose=purpComp, rc=rc)
    call ESMF_AttributeSet(comp, "LongName", "Land Dead Model", convention=convCIM, purpose=purpComp, rc=rc)
    call ESMF_AttributeSet(comp, "Description", &
         "The dead models stand in as test model for active components." // &
         "Coupling data is artificially generated ", convention=convCIM, purpose=purpComp, rc=rc)
    call ESMF_AttributeSet(comp, "ReleaseDate", "2017", convention=convCIM, purpose=purpComp, rc=rc)
    call ESMF_AttributeSet(comp, "ModelType", "Land", convention=convCIM, purpose=purpComp, rc=rc)
#endif

    call shr_file_setLogLevel(shrloglev)
    call shr_file_setLogUnit (shrlogunit)

    if (dbug > 5) call ESMF_LogWrite(subname//' done', ESMF_LOGMSG_INFO, rc=dbrc)

  end subroutine InitializeRealize

  !===============================================================================

  subroutine ModelAdvance(gcomp, rc)
    use shr_nuopc_utils_mod, only : shr_nuopc_memcheck
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    ! local variables
    type(ESMF_Clock)         :: clock
    type(ESMF_State)         :: importState, exportState
    integer                  :: n
    integer                  :: shrlogunit     ! original log unit
    integer                  :: shrloglev      ! original log level
    character(len=*),parameter  :: subname=trim(modName)//':(ModelAdvance) '
    !-------------------------------------------------------------------------------

    rc = ESMF_SUCCESS
    if (dbug > 5) then
       call ESMF_LogWrite(subname//' called', ESMF_LOGMSG_INFO, rc=dbrc)
    endif
    call shr_nuopc_memcheck(subname, 3, mastertask)
    call shr_file_getLogUnit (shrlogunit)
    call shr_file_getLogLevel(shrloglev)
    call shr_file_setLogLevel(max(shrloglev,1))
    call shr_file_setLogUnit (logunit)

    !--------------------------------
    ! query the Component for its clock, importState and exportState
    !--------------------------------

    call NUOPC_ModelGet(gcomp, modelClock=clock, importState=importState, &
      exportState=exportState, rc=rc)
    if (shr_nuopc_methods_ChkErr(rc,__LINE__,u_FILE_u)) return


    if (dbug > 1) then
      call shr_nuopc_methods_Clock_TimePrint(clock,subname//'clock',rc=rc)
    endif

    !--------------------------------
    ! Unpack import state
    !--------------------------------

    do n = 1, FldsFrLnd_num
       if (fldsFrLnd(n)%stdname /= flds_scalar_name) then
          call state_getimport(importState, trim(fldsToLnd(n)%stdname), x2d(n,:), rc=rc)
          if (shr_nuopc_methods_ChkErr(rc,__LINE__,u_FILE_u)) return
       end if
    end do

    !--------------------------------
    ! Run model
    !--------------------------------

    call dead_run_nuopc('lnd', d2x, gbuf, flds_l2x)

    !--------------------------------
    ! Pack export state
    !--------------------------------

    do n = 1, FldsFrLnd_num
       if (fldsFrLnd(n)%stdname /= flds_scalar_name) then
          call state_setexport(exportState, trim(fldsFrLnd(n)%stdname), d2x(n,:), rc=rc)
          if (shr_nuopc_methods_ChkErr(rc,__LINE__,u_FILE_u)) return
       end if
    end do

    !--------------------------------
    ! diagnostics
    !--------------------------------

    if (dbug > 1) then
       if (my_task == master_task) then
          call Print_FieldExchInfo(values=d2x, logunit=logunit, &
               fldlist=fldsFrLnd, nflds=fldsFrLnd_num, istr="ModelAdvance: lnd->mediator")
       end if
       call shr_nuopc_methods_State_diagnose(exportState,subname//':ES',rc=rc)
       if (shr_nuopc_methods_ChkErr(rc,__LINE__,u_FILE_u)) return

       call ESMF_ClockPrint(clock, options="currTime", preString="------>Advancing LND from: ", rc=rc)
       if (shr_nuopc_methods_ChkErr(rc,__LINE__,u_FILE_u)) return

       call ESMF_ClockPrint(clock, options="stopTime", preString="--------------------------------> to: ", rc=rc)
       if (shr_nuopc_methods_ChkErr(rc,__LINE__,u_FILE_u)) return
    endif

    call shr_file_setLogLevel(shrloglev)
    call shr_file_setLogUnit (shrlogunit)

    if (dbug > 5) call ESMF_LogWrite(subname//' done', ESMF_LOGMSG_INFO, rc=dbrc)

  end subroutine ModelAdvance

  !===============================================================================

  subroutine ModelFinalize(gcomp, rc)
    type(ESMF_GridComp)  :: gcomp
    integer, intent(out) :: rc

    ! local variables
    character(len=*),parameter  :: subname=trim(modName)//':(ModelFinalize) '
    !-------------------------------------------------------------------------------

    !--------------------------------
    ! Finalize routine
    !--------------------------------

    rc = ESMF_SUCCESS
    if (dbug > 5) call ESMF_LogWrite(subname//' called', ESMF_LOGMSG_INFO, rc=dbrc)

    call dead_final_nuopc('lnd', logunit)

    if (dbug > 5) call ESMF_LogWrite(subname//' done', ESMF_LOGMSG_INFO, rc=dbrc)

  end subroutine ModelFinalize

end module lnd_comp_nuopc
