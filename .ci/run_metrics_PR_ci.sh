#!/bin/bash
# Copyright (c) 2017-2018 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0

# Note - no 'set -e' in this file - if one of the metrics tests fails
# then we wish to continue to try the rest.
# Finally at the end, in some situations, we explicitly exit with a
# failure code if necessary.

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "${SCRIPT_DIR}/../metrics/lib/common.bash"
RESULTS_DIR=${SCRIPT_DIR}/../metrics/results
CHECKMETRICS_DIR=${SCRIPT_DIR}/../cmd/checkmetrics
# Where to look by default, if this machine is not a static CI machine with a fixed name.
CHECKMETRICS_CONFIG_DEFDIR="/etc/checkmetrics"
# Where to look if this machine is a static CI machine with a known fixed name.
CHECKMETRICS_CONFIG_DIR="${CHECKMETRICS_DIR}/ci_slaves"
CM_DEFAULT_DENSITY_CONFIG="${CHECKMETRICS_DIR}/baseline/density-CI.toml"

# Set up the initial state
init() {
	metrics_onetime_init
}

# Execute metrics scripts
run() {
	pushd "$SCRIPT_DIR/../metrics"

	# If KSM is available on this platform, let's run any tests that are
	# affected by having KSM on/orr first, and then turn it off for the
	# rest of the tests, as KSM may introduce some extra noise in the
	# results by stealing CPU time for instance.
	if [[ -f ${KSM_ENABLE_FILE} ]]; then
		save_ksm_settings
		trap restore_ksm_settings EXIT QUIT KILL
		set_ksm_aggressive

		# Run the memory footprint test - the main test that
		# KSM affects.
		bash density/docker_memory_usage.sh 20 300 auto

		# And now ensure KSM is turned off for the rest of the tests
		disable_ksm
	fi

	# Run the density tests - no KSM, so no need to wait for settle
	# (so set a token 5s wait)
	bash density/docker_memory_usage.sh 20 5

	# Run the density test inside the container
	bash density/memory_usage_inside_container.sh

	# We only run these tests if we are not on a transient cloud machine. We
	# need a repeatable non-noisy environment for these tests to be useful.
	if [ -z "${METRICS_CI_CLOUD}" ]; then
		# Run the time tests
		bash time/launch_times.sh -i ubuntu -n 20

		# Run storage tests
		bash storage/blogbench.sh

		# Run the cpu statistics test
		bash network/cpu_statistics_iperf.sh
	fi
	popd
}

# Check the results
check() {
	if [ -n "${METRICS_CI}" ]; then
		# Ensure we have the latest checkemtrics
		pushd "$CHECKMETRICS_DIR"
		make
		sudo make install
		popd

		# FIXME - we need to document the whole metrics CI setup, and the ways it
		# can be configured and adapted. See:
		# https://github.com/kata-containers/ci/issues/58
		#
		# If we are running on a (transient) cloud machine then we cannot
		# tie the name of the expected results config file to the machine name - but
		# we can expect the cloud image to have a default named file in the correct
		# place.
		if [ -n "${METRICS_CI_CLOUD}" ]; then
			local CM_BASE_FILE="${CHECKMETRICS_CONFIG_DEFDIR}/checkmetrics-json.toml"

			# If we don't have a machine specific file in place, then copy
			# over the default cloud density file.
			if [ ! -f ${CM_BASE_FILE} ]; then
				sudo mkdir -p ${CHECKMETRICS_CONFIG_DEFDIR}
				sudo cp ${CM_DEFAULT_DENSITY_CONFIG} ${CM_BASE_FILE}
			fi
		elif [ -n "${METRICS_CI_PROFILE}" ]; then
			case "${METRICS_CI_PROFILE}" in
				"clh-baremetal")
					local CM_BASE_FILE="${CHECKMETRICS_CONFIG_DIR}/checkmetrics-json-clh-baremetal-$(uname -n).toml"
					;;
				"qemu-cloud")
					local CM_BASE_FILE="${CHECKMETRICS_CONFIG_DEFDIR}/checkmetrics-json.toml"
					;;
				"virtiofs-baremetal")
					local CM_BASE_FILE="${CHECKMETRICS_CONFIG_DIR}/checkmetrics-json-virtiofs-baremetal-$(uname -n).toml"
					;;
				*)
					die "unknown METRICS_CI_PROFILE=${METRICS_CI_PROFILE}"
			esac

		else
			# For bare metal repeatable machines, the config file name is tied
			# to the uname of the machine.
			local CM_BASE_FILE="${CHECKMETRICS_CONFIG_DIR}/checkmetrics-json-$(uname -n).toml"
		fi
		info "CM_BASE_FILE=${CM_BASE_FILE}"
		checkmetrics --percentage --debug --basefile ${CM_BASE_FILE} --metricsdir ${RESULTS_DIR}
		cm_result=$?
		if [ ${cm_result} != 0 ]; then
			echo "checkmetrics FAILED (${cm_result})"
			exit ${cm_result}
		fi

		if [  "${METRICS_JOB_BASELINE:-}" != "" ];then
			"${SCRIPT_DIR}/../cmd/checkmetrics/history/generate_report_from_job.sh" "${METRICS_JOB_BASELINE}" || true
		fi
	fi
}

teardown() {
	docker_configuration_path="/etc/docker"
	docker_configuration_file="${docker_configuration_path}/daemon.json"
	if [ -f "${docker_configuration_file}" ]; then
		sudo rm -f "${docker_configuration_file}"
	fi
}

trap teardown EXIT QUIT KILL

init
run
check
