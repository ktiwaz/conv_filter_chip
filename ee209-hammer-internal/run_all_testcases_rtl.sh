#!/usr/bin/env bash
set -u

# ============================================================
# Configuration
# ============================================================

TESTCASES_DIR="../testcases"
HAMMER_DIR="../ee209-hammer-internal"
MAKEFILE="Makefile"

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

    # Normalize:
    # - remove CRs
    # - drop blank lines
    # - trim leading/trailing whitespace
    # - uppercase for case-insensitive compare
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
# Step 1: delete all existing output_image.hex files
# ============================================================

echo "Deleting existing output_image.hex files under ${TESTCASES_DIR} ..."
find "$TESTCASES_DIR" -type f -name "output_image.hex" -delete

# ============================================================
# Step 2: iterate through all config.yml testcases
# ============================================================

while IFS= read -r yml_path; do
    testcase_dir="$(dirname "$yml_path")"
    testcase_name="${testcase_dir#$TESTCASES_DIR/}"

    output_file="${testcase_dir}/output_image.hex"
    expected_file="${testcase_dir}/expected_output_image.hex"

    echo
    echo "============================================================"
    echo "Running testcase: ${testcase_name}"
    echo "Config: ${yml_path}"
    echo "============================================================"

    if [[ ! -f "$expected_file" ]]; then
        echo "SKIP: missing input file: $expected_file"
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

    (
        cd "$HAMMER_DIR" || exit 100

        echo "[1/2] Cleaning build ..."
        make -f "$MAKEFILE" clean-build
    )
    clean_status=$?

    if [[ $clean_status -ne 0 ]]; then
        echo "FAIL: clean-build failed for ${testcase_name}"
        failed_tests+=("$testcase_name (clean-build failed)")
        fail_count=$((fail_count + 1))
        continue
    fi

    (
        cd "$HAMMER_DIR" || exit 101

        echo "[2/2] Running testcase ..."
        make -f "$MAKEFILE" sim-rtl TB_CFGS="$yml_path"
    )
    run_status=$?

    if [[ $run_status -ne 0 ]]; then
        echo "FAIL: simulation/make failed for ${testcase_name}"
        failed_tests+=("$testcase_name (make run failed)")
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

done < <(find "$TESTCASES_DIR" -type f -name "config.yml" | sort)

# ============================================================
# Final report
# ============================================================

echo
echo "============================================================"
echo "FINAL REPORT"
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