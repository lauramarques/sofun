############################
# SOFUN master Makefile
# adopted from LPX Makefile
############################

##################################
## Select configuration profile ##
##################################
# pgf     - PGF95 compiler
# gfor    - gfortran compiler
# intel   - ifort compiler

PROFILE=gfortran
# PROFILE=pgi
# PROFILE=intel

##################
## pgf profile ##
##################
ifeq ($(PROFILE),pgi)
# Compiler and options
FCOM=pgf95 
CPPFLAGS=-E
COMPFLAGS=-g -O2 -fdefault-real-8 -ffree-line-length-0 -fbacktrace -ffpe-trap=invalid,zero,overflow -pedantic-errors # for normal setup
# COMPFLAGS=-g -O0 -r8 -Mextend -Mbounds -Minfo -Minform=inform -Kieee -Ktrap=fp -Mfreeform  # debug flags, real8
#COMPFLAGS= -Mextend -Mdalign -Kieee -Ktrap=fp -O2 -Mprof=lines # to analyze computation time by subroutines
DEBUGFLAGS=-g -O0 -Mextend -Mbounds -Minfo -Minform=inform -Kieee -Ktrap=fp -Mfreeform

# System libraries
# LIBS = -L $(NETCDF_LIB) -lnetcdf -lnetcdff
endif

#################
## gfortran profile ##
##################
ifeq ($(PROFILE),gfortran)
# Compiler and options
FCOM=gfortran
CPPFLAGS=-cpp -E
COMPFLAGS=-g -O2 -fdefault-real-8 -ffree-line-length-0 -fbacktrace -ffpe-trap=invalid,zero,overflow -pedantic-errors # for normal setup
# COMPFLAGS=-g -O0 -r8 -Mextend -Mbounds -Minfo -Minform=inform -Kieee -Ktrap=fp -Mfreeform  # debug flags, real8
#COMPFLAGS= -Mextend -Mdalign -Kieee -Ktrap=fp -O2 -Mprof=lines # to analyze computation time by subroutines
# DEBUGFLAGS=-g -O0 -Mextend -Mbounds -Minfo -Minform=inform -Kieee -Ktrap=fp -Mfreeform

# # System libraries
# LIBS = -L $(NETCDF_LIB) -lnetcdf -lnetcdff

NETCDF_INC = /opt/local/include
NETCDF_LIB = /opt/local/lib
# LIBS = -L $(NETCDF_LIB) -lnetcdf
LIBS = -L $(NETCDF_LIB) -lnetcdf -lnetcdff -lgfortran

endif

#####################
## intel profile ##
#####################
ifeq ($(PROFILE),intel)
# Compiler and options
FCOM=ifort
CPPFLAGS=-e -fpp -preprocess_only -E
COMPFLAGS=-O3 -xSSE4.2 -axAVX,CORE-AVX-I,CORE-AVX2 -extend_source -free -g -traceback ##-r8 -i4 -align -pc64 -fp-model strict 
DEBUGFLAGS=-O3 -xSSE4.2 -axAVX,CORE-AVX-I,CORE-AVX2 -extend_source -free -warn all -implicitnone -g -traceback -fpe0 -fpstkchk -CU

# System libraries
# Get netcdf-fortran library by 'sudo port install netcdf-fortran'
# and to see where it's been installed 'port contents netcdf-fortran'
# NETCDF_INC = /opt/local/include
# NETCDF_LIB = /opt/local/lib
# LIBS = -L $(NETCDF_LIB) -lnetcdf
endif

####################
## general config ##
####################

# Check if FCOM is set
ifeq ($(strip $(FCOM)),)
$(error 'ERROR. Select a valid configuration profile in the Makefile (e.g. PROFILE=gfor).')
endif

# Add flags for MPI parallelization (enable the following lines when the parallel_mpi feature is turned on)
#LIBS += $(shell mpif90 --showme:link)
#COMPFLAGS += $(shell mpif90 --showme:compile)
#DEBUGFLAGS += $(shell mpif90 --showme:compile)

# Add library include files to compiler flags
COMPFLAGS += -I$(NETCDF_INC)
DEBUGFLAGS += -I$(NETCDF_INC)

# name of executable
EXE              = runsofun
SPLASH_EXE       = runsplash
SWBM_EXE         = runswbm
PMODEL_EXE       = runpmodel
PMODEL_SWBM_EXE  = runpmodel_swbm
GPMODEL_EXE      = rungpmodel
CMODEL_EXE       = runcmodel
TMODEL_EXE       = runtmodel
CNMODEL_EXE      = runcnmodel

ARCHIVES= ./src/sofun.a
# ARLPJ= ./lpj/lpj.a (archive names when compiling with different option)

# Export variables that are needed by Makefiles in the subdirectories (called below)
export FCOM CPPFLAGS COMPFLAGS DEBUGFLAGS LIBS

# Targets
# -------
standard: 
	 $(MAKE) -C src
	 $(FCOM) -o $(EXE) $(COMPFLAGS) $(ARCHIVES)
	 
#  include libraries when necessary
#	 $(FCOM) -o $(EXE) $(COMPFLAGS) $(ARCHIVES) $(LIBS)

# code for debugging:
debug: 
	$(MAKE) debug -C src
	$(FCOM) -o $(EXE) $(DEBUGFLAGS) $(ARCHIVES) #$(LIBS)

# reduced model setup: only SPLASH
splash: 
	 $(MAKE) splash -C src
	 $(FCOM) -o $(SPLASH_EXE) $(COMPFLAGS) $(ARCHIVES)

# reduced model setup: only SPLASH
swbm: 
	 $(MAKE) swbm -C src
	 $(FCOM) -o $(SWBM_EXE) $(COMPFLAGS) $(ARCHIVES)

# reduced model setup: only SPLASH and PMODEL
pmodel: 
	 $(MAKE) pmodel -C src
	 $(FCOM) -o $(PMODEL_EXE) $(COMPFLAGS) $(ARCHIVES) $(LIBS)

# reduced model setup: only SPLASH and PMODEL
dbgpmodel: 
	 $(MAKE) pmodel -C src
	 $(FCOM) -o $(PMODEL_EXE) $(DEBUGFLAGS) $(ARCHIVES) $(LIBS)

pmodel_swbm: 
	 $(MAKE) pmodel_swbm -C src
	 $(FCOM) -o $(PMODEL_SWBM_EXE) $(COMPFLAGS) $(ARCHIVES)

# reduced model setup: only SPLASH and PMODEL
gpmodel: 
	 $(MAKE) gpmodel -C src
	 $(FCOM) -o $(GPMODEL_EXE) $(COMPFLAGS) $(ARCHIVES) $(LIBS)

# reduced model setup: fixed allocation, no litter, soil and inorganic C and N dynamics
cmodel: 
	 $(MAKE) cmodel -C src
	 $(FCOM) -o $(CMODEL_EXE) $(COMPFLAGS) $(ARCHIVES)

# reduced model setup: fixed allocation, no litter, soil and inorganic C and N dynamics
tmodel: 
	 $(MAKE) tmodel -C src
	 $(FCOM) -o $(TMODEL_EXE) $(COMPFLAGS) $(ARCHIVES)

# full model setup
cnmodel: 
	 $(MAKE) cnmodel -C src
	 $(FCOM) -o $(CNMODEL_EXE) $(COMPFLAGS) $(ARCHIVES)

# clean: remove exe and .o and .do files
.PHONY: clean
clean:
	-rm $(EXE) $(SPLASH_EXE) $(SWBM_EXE) $(PMODEL_EXE) $(GPMODEL_EXE) $(CMODEL_EXE) $(TMODEL_EXE) $(CNMODEL_EXE)
	$(MAKE) clean -C src
# include libraries when necessary
#	$(MAKE) clean -C lpj/cdfcode

#EOF