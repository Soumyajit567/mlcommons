#!/usr/bin/bash
# ... SBATCH --job-name=mlcommons-eq-{experiment.card_name}-{experiment.gpu_count}
# ... SBATCH --output=%u-%j.out
# ... SBATCH --error=%u-%j.err
# ... SBATCH --partition={system.partition}
# ... SBATCH -c {experiment.cpu_num}
# ... SBATCH --mem={experiment.mem}
# ... SBATCH --time={time}
## # ... SBATCH --gres=gpu:{experiment.card_name}:{experiment.gpu_count}
# ... SBATCH --mail-user={email}
# ... SBATCH --mail-type=ALL
# ... SBATCH --account={user.account}


set -uxe

# This has not yet cms gpu watch into a logfile we want to specify in the config.yaml
# cms gpu watch
# cms gpu watch [--gpu=GPU] [--delay=SECONDS] [--logfile=LOGFILE] [--count=COUNT] [--dense]
# with &

### BEGIN CONFIGURATION

## Specifies the path to save the final output
NB_OUTPUT="_output"

## Unique identifier to isolate executions from each other.
RUN_ID="${RUN_ID:-{meta.uuid}}"

## Set the python version to target
PYTHON_VERSION={system.python}

## Specifies the git branch to use from the repository
## by default using {run.branch}
## The SAFE version cleans the name of any path-like characters
BRANCH=${BRANCH:-{run.branch}}
#BRANCH_SAFE=${BRANCH/\//-}
BRANCH_SAFE=${BRANCH}


## Specifies a github fork to use when running the build
FORK=${FORK:-"laszewsk"}

## Specifies the primary directory to use when running the
## benchmark.  When not specifies, it assumes the username
## on the sytem as the directory.
MLCOMMONS_HOME=${MLCOMMONS_HOME:-{run.workdir}}

## Specifies a specific revision of the Earthquake notebook
## Used to select the different folder names in the earthquake
## directory
REV="{revision}"

## Specifies the path that contains utilities on the HPC
## cluster, such as the system scripts.
RESOURCE_DIR="{run.resourcedir}"


### END CONFIGURATION



### FUNCTION BEGIN
# Finds the current user's common name from the current operating
# environment.
### FUNCTION END
#function DETECT_RUN_USER() {
DETECT_RUN_USER() {
   # Gets the current username from the current system password database
   # will be an empty string if the command fails or a bad username is
   # supplied

   #local MY_NAME="$(getent passwd $(whoami) | cut -d: -f5 || true)"
   ## When the username is not known or the password database cannot run
   ## set the value to the current system username
   #if [ x"${MY_NAME}" == x"" ]; then
   #     echo $(whoami)
   ## Otherwise, use the human friendly username
   #else
   #     echo ${MY_NAME}
   #fi
   echo $(whoami)
}


## Specifies the username to apply when running on a
## clustrered environment
RUN_USER="$(DETECT_RUN_USER)"
LOCKDB=${MLCOMMONS_HOME}/${RUN_USER}

## Sets up the base directory for running the experiment from the
## previously defined vars.
RUN_BASE=${MLCOMMONS_HOME}/${RUN_USER}/workspace-${RUN_ID}
VENV_PATH={run.venvpath}
GIT_BASEPATH=${MLCOMMONS_HOME}/${RUN_USER}/git

# Cleanup locks and temporary files on failed execution
trap "rm -f ${MLCOMMONS_HOME}/${LOCKDB}/.*.lock ; exit" 1 2 3 6 15


### FUNCTION BEGIN
# Performs a git checkout
# GLOBALS:
#   MLCOMMONS_HOME
#   GIT_REV
# ARGUMENTS:
#   $1 - The url to use with the git command
#   $2 - The folder to place the cloned repo into
#   $3 - The branch to checkout after cloning.  By default, this is "main".
# OUTPUTS:
#   Git command line output
### FUNCTION END
git_checkout() {
# function git_checkout() {
    local repo_url=$1
    local target=${2:-$(basename ${repo_url} .git)}
    local branch=${3:-main}

    # Make sure the base directory we're cloning into exists.
    local target_lead=$(dirname $target)
    mkdir -p ${target_lead}

    # Clone the repo if it doesn't already exist and switch to the
    # targeted branch.
    if [ ! -e "$target" ]; then
        git clone $repo_url $target
        (cd $target && \
            git checkout $branch)
    # Ensure that the current checkout doesn't have any local edits
    # and checks out the named branch.
    else
        (cd $target && \
            git fetch origin  && \
            git checkout $branch && \
            git reset --hard origin/$branch && \
            git clean -d --force)
    fi
    GIT_REV="$(cd "$target" && git rev-parse --short=8 HEAD)"
}


### FUNCTION BEGIN
# Creates a file lock handle.  Creates an empty file in
# $MLCOMMONS_HOME with the passed name as a dot file.
# GLOBALS:
#   LOCKDB
# ARGUMENTS:
#   $1 - The lock name to register in MLCOMMONS_HOME
### FUNCTION END
make_lock() {
# function make_lock() {
    local lockname="${LOCKDB}/.$1.lock"
    touch "${lockname}"
}

### FUNCTION BEGIN
# Releases a file lock handle.  Deletes an empty file in
# $MLCOMMONS_HOME with the passed name as a dot file.
# GLOBALS:
#   LOCKDB
# ARGUMENTS:
#   $1 - The lock name to register in MLCOMMONS_HOME
### FUNCTION END
# function release_lock() {
release_lock() {
    local lockname="${LOCKDB}/.$1.lock"
    if [ -e "${lockname}" ] ; then
      rm -f "${lockname}"
    fi
}

### FUNCTION BEGIN
# Deadwait function that stops execution while the named
# lock is present on the filesystem.
# GLOBALS:
#   LOCKDB
# ARGUMENTS:
#   $1 - The lock name to register in MLCOMMONS_HOME
#   $2 - The duration to wait in seconds.  Defaults to 5 seconds.
# OUTPUTS:
#   Prints a dot every increment that the file lock is present.
### FUNCTION END
wait_lock() {
# function wait_lock() {
    local lockname="${LOCKDB}/.$1.lock"
    local delay=${2:-1}
    printf "Checking for lock ${lockname}"
    while [ -e ${lockname} ] ; do
      printf "."
      sleep $delay
    done
    printf ". Done\n"
}

### FUNCTION BEGIN
# Utility function that waits until the named lock has been released
# and then immediately claims the lock.
# CALLTREE:
#   wait_lock
#   make_lock
# ARGUMENTS:
#   $1 - The lock name to use for wait_lock and make_lock
#   $2 - The duration to wait in seconds.  Defaults to 5 seconds.
# OUTPUTS:
#   Prints a dot every increment that the file lock is present.
### FUNCTION END
waitmake_lock() {
# function waitmake_lock() {
    wait_lock $1 ${2:-1}
    make_lock $1
}



### FUNCTION BEGIN
# Creates a virtual environment in a specified directory using a
# specific requirements.txt file.
# GLOBALS
#   RUN_BASE
# CALLTREE
#   waitmake_lock
# ARGUMENTS
#   $1 - The folder to establish the python virtual environment into
#   $2 - The path to a python requirements.txt file
### FUNCTION END
setup_venv(){
# function setup_venv(){
    local target=$1
    local requirements_path=$2
    # Prevent parallel updates to pip
    waitmake_lock pip.lock
        python -m venv --upgrade-deps ${target}
	case "$(uname -s)" in
	  MINGW*) source ${target}/Scripts/activate ;;
	  *) source ${target}/bin/activate ;;
        esac
        python -m pip install -r ${requirements_path} \
            --progress-bar off
        python -m pip install cloudmesh-gpu --progress-bar off
        python -m pip freeze > ${RUN_BASE}/pip-freeze.txt
    release_lock pip.lock
}


mkdir -p ${RUN_BASE}
RUN_BASE_ABS=$(realpath ${RUN_BASE})

echo "Working in <$(pwd)>"
echo "Base directory in <${RUN_BASE}>"
echo "MLCommons home in <${MLCOMMONS_HOME}>"
echo "Revision: <${REV}>"
echo "Script: <{script}>"
echo "Python: <${PYTHON_VERSION}>"
echo "Run ID: <${RUN_ID}>"


if [ -e "$(pwd)/config.yaml" ]; then
	cp $(pwd)/config.yaml ${RUN_BASE_ABS}
fi



# Checkout git repo for mlcommons earthquake data, locking the repo
# to prevent concurrent git operations
waitmake_lock mlcommons-data-earthquake.git
    git_checkout https://github.com/laszewsk/mlcommons-data-earthquake.git \
                 "${GIT_BASEPATH}/mlcommons-data-earthquake" \
                 main
release_lock mlcommons-data-earthquake.git

# Checkout git repo for mlcommons main repository, locking the repo
# to prevent concurrent git operations
waitmake_lock mlcommons.git
    git_checkout https://github.com/laszewsk/mlcommons.git \
                 "${GIT_BASEPATH}/mlcommons" \
                 $BRANCH
    # Extract the mlcommons eearthquake data to the required path.
    if [ ! -e ${RUN_BASE}/data/EarthquakeDec2020 ]; then
        tar Jxvf ${GIT_BASEPATH}/mlcommons-data-earthquake/data.tar.xz \
            -C ${RUN_BASE}
        # BUG; should be in zip file (or created as part of the python file
        mkdir -p ${RUN_BASE}/data/EarthquakeDec2020/Outputs
    fi

    # Create a python virtual environment based on the current benchmark's requirements.txt file
    setup_venv ${VENV_PATH} \
               ${GIT_BASEPATH}/mlcommons/benchmarks/earthquake/${REV}/requirements.txt

    # Copy the earthquake notebook into our working directory to prevent any modifications to the git repo.
    mkdir -p ${NB_OUTPUT}
    cp ${GIT_BASEPATH}/mlcommons/benchmarks/earthquake/${REV}/{script} \
       ${RUN_BASE}/FFFFWNPFEARTHQ_newTFTv29-${RUN_USER}-${GIT_REV}.ipynb
release_lock mlcommons.git

# Watch visable cards if the variable is set
# otherwise monitor all
if [ -z "${CUDA_VISIBLE_DEVICES+x}" ]; then
  GPU_SWITCH="--gpu=${CUDA_VISIBLE_DEVICES}"
else
  GPU_SWITCH=" "
fi

cms gpu watch --delay=1 ${GPU_SWITCH} --dense > ${RUN_BASE}/data/EarthquakeDec2020/Outputs/gpu0.log &
GPU_MONITOR=$!

# Execute the notebook using papermill
papermill "${RUN_BASE}/FFFFWNPFEARTHQ_newTFTv29-${RUN_USER}-${GIT_REV}.ipynb" \
          "${RUN_BASE}/FFFFWNPFEARTHQ_newTFTv29-${RUN_USER}-${GIT_REV}_output.ipynb" \
          --no-progress-bar --log-output --log-level INFO

# Save the final notebook after everything's done
echo "Saving final notebook to ${NB_OUTPUT}"
cp "${RUN_BASE}/FFFFWNPFEARTHQ_newTFTv29-${RUN_USER}-${GIT_REV}_output.ipynb" \
   "${NB_OUTPUT}/FFFFWNPFEARTHQ_newTFTv29-${GIT_REV}_output.ipynb"

echo "Saving outputs to ${NB_OUTPUT}"
mkdir -p ${NB_OUTPUT}
cp -R "${RUN_BASE}/data/EarthquakeDec2020/Outputs" ${NB_OUTPUT}

echo "Stopping background tasks."
kill -SIGTERM ${GPU_MONITOR}

echo "Execution Complete"
exit 0
