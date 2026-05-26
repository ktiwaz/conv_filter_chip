#!/usr/bin/env bash
set -u

# ============================================================
# Configuration
# ============================================================

TESTCASES_DIR="../testcases"
HAMMER_DIR="../ee209-hammer-internal"
MAKEFILE="Makefile"

# ============================================================
# Argument: 3x3 or 5x5
# ============================================================

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 {3x3|5x5}"
    exit 1
fi

KERNEL_SIZE_DIR="$1"

if [[ "$KERNEL_SIZE_DIR" != "3x3" && "$KERNEL_SIZE_DIR" != "5x5" ]]; then
    echo "Error: argument must be either 3x3 or 5x5"
    exit 1
fi

SELECTED_TESTCASES_DIR="${TESTCASES_DIR}/${KERNEL_SIZE_DIR}"

if [[ ! -d "$SELECTED_TESTCASES_DIR" ]]; then
    echo "Error: testcase directory does not exist: $SELECTED_TESTCASES_DIR"
    exit 1
fi

# ============================================================
# Helpers
# ============================================================

pass_count=0
fail_count=0
skip_count=0

declare -a passed_tests=()
declare -a failed_tests=()
declare -a skipped_tests=()

compare_hex_files_case_insensitive() {
    local file_a="$1"
    local file_b="$2"

    if [[ ! -f "$file_a" || ! -f "$file_b" ]]; then
        return 2
    fi

    local norm_a norm_b
    norm_a="$(mktemp)"
    norm_b="$(mktemp)"

    sed 's/\r$//' "$file_a" \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
        | grep -v '^$' \
        | tr '[:lower:]' '[:upper:]' > "$norm_a"

    sed 's/\r$//' "$file_b" \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
        | grep -v '^$' \
        | tr '[:lower:]' '[:upper:]' > "$norm_b"

    if cmp -s "$norm_a" "$norm_b"; then
        rm -f "$norm_a" "$norm_b"
        return 0
    else
        rm -f "$norm_a" "$norm_b"
        return 1
    fi
}

# ============================================================
# Step 1: delete existing actual outputs for selected size only
# ============================================================

echo "Running only ${KERNEL_SIZE_DIR} post-synthesis testcases"
echo "Deleting existing output_image.hex files under ${SELECTED_TESTCASES_DIR} ..."
find "$SELECTED_TESTCASES_DIR" -type f -name "output_image.hex" -delete

# ============================================================
# Step 2: iterate through selected post-synthesis configs
# ============================================================

while IFS= read -r yml_path; do
    testcase_dir="$(dirname "$yml_path")"
    testcase_name="${testcase_dir#$TESTCASES_DIR/}"

    output_file="${testcase_dir}/output_image.hex"
    expected_file="${testcase_dir}/expected_output_image.hex"

    echo
    echo "============================================================"
    echo "Running post-syn testcase: ${testcase_name}"
    echo "Config: ${yml_path}"
    echo "============================================================"

    if [[ ! -f "$expected_file" ]]; then
        echo "SKIP: missing expected file: $expected_file"
        skipped_tests+=("$testcase_name (missing expected_output_image.hex)")
        skip_count=$((skip_count + 1))
        continue
    fi

    if [[ ! -d "$HAMMER_DIR" ]]; then
        echo "FAIL: hammer directory not found: $HAMMER_DIR"
        failed_tests+=("$testcase_name (missing hammer dir)")
        fail_count=$((fail_count + 1))
        continue
    fi

    echo "[1/2] Cleaning post-syn sim rundir ..."
    rm -rf "$HAMMER_DIR/build/sim-syn-rundir"
    clean_status=$?

    if [[ $clean_status -ne 0 ]]; then
        echo "FAIL: clean failed for ${testcase_name}"
        failed_tests+=("$testcase_name (clean failed)")
        fail_count=$((fail_count + 1))
        continue
    fi

    (
        cd "$HAMMER_DIR" || exit 101

        echo "[2/2] Running post-syn testcase ..."
        make -f "$MAKEFILE" sim-syn TB_CFGS="$yml_path"
    )
    run_status=$?

    if [[ $run_status -ne 0 ]]; then
        echo "FAIL: post-syn simulation/make failed for ${testcase_name}"
        failed_tests+=("$testcase_name (make sim-syn failed)")
        fail_count=$((fail_count + 1))
        continue
    fi

    if [[ ! -f "$output_file" ]]; then
        echo "FAIL: output file was not generated: $output_file"
        failed_tests+=("$testcase_name (missing output_image.hex)")
        fail_count=$((fail_count + 1))
        continue
    fi

    compare_hex_files_case_insensitive "$output_file" "$expected_file"
    cmp_status=$?

    if [[ $cmp_status -eq 0 ]]; then
        echo "PASS: ${testcase_name}"
        passed_tests+=("$testcase_name")
        pass_count=$((pass_count + 1))
    elif [[ $cmp_status -eq 1 ]]; then
        echo "FAIL: ${testcase_name} (output_image.hex != expected_output_image.hex)"
        failed_tests+=("$testcase_name (file mismatch)")
        fail_count=$((fail_count + 1))
    else
        echo "FAIL: ${testcase_name} (could not compare files)"
        failed_tests+=("$testcase_name (compare error)")
        fail_count=$((fail_count + 1))
    fi

done < <(find "$SELECTED_TESTCASES_DIR" -type f -name "config_post_syn.yml" | sort)

# ============================================================
# Final report
# ============================================================

echo
echo "============================================================"
echo "POST-SYN FINAL REPORT: ${KERNEL_SIZE_DIR}"
echo "============================================================"
echo "Passed : $pass_count"
echo "Failed : $fail_count"
echo "Skipped: $skip_count"

echo
echo "PASSED TESTCASES:"
if [[ ${#passed_tests[@]} -eq 0 ]]; then
    echo "  (none)"
else
    for t in "${passed_tests[@]}"; do
        echo "  $t"
    done
fi

echo
echo "FAILED TESTCASES:"
if [[ ${#failed_tests[@]} -eq 0 ]]; then
    echo "  (none)"
else
    for t in "${failed_tests[@]}"; do
        echo "  $t"
    done
fi

echo
echo "SKIPPED TESTCASES:"
if [[ ${#skipped_tests[@]} -eq 0 ]]; then
    echo "  (none)"
else
    for t in "${skipped_tests[@]}"; do
        echo "  $t"
    done
fi