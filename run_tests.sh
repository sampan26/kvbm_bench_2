#!/bin/bash

# Test runner for KVBM performance testing using long_doc_qa benchmark
# Usage: ./run_test.sh <config> [model_size] [--output-dir <path>] [--prefix <name>]
# config: baseline, production, connector, lmcache
# model_size: 8B (default) or 70B
# --output-dir: Directory to save results (optional, defaults to ./results)
# --prefix: Custom prefix for result files (optional, defaults to {config}_{model}_{timestamp})
#
# Examples:
#   ./run_test.sh baseline                              # Test baseline with 8B in ./results
#   ./run_test.sh production 70B                       # Test production with 70B in ./results
#   ./run_test.sh connector --output-dir /custom/path  # Test connector with 8B in custom path
#   ./run_test.sh lmcache 8B --output-dir ./test_run   # Test lmcache with 8B in ./test_run
#   ./run_test.sh production --prefix my_experiment     # Custom prefix: my_experiment_output_1.csv

set -e

# Default values
CONFIG=""
MODEL_SIZE="8B"
RESULTS_DIR="./results"
CUSTOM_PREFIX=""
BENCHMARK_SCRIPT="LMCache/benchmarks/long_doc_qa/long_doc_qa.py"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --output-dir)
            RESULTS_DIR="$2"
            shift 2
            ;;
        --prefix)
            CUSTOM_PREFIX="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 <config> [model_size] [--output-dir <path>] [--prefix <name>]"
            echo ""
            echo "Arguments:"
            echo "  config       Configuration to test: baseline, production, connector, lmcache"
            echo "  model_size   Model size: 8B (default) or 70B"
            echo "  --output-dir Directory to save results (optional, defaults to ./results)"
            echo "  --prefix     Custom prefix for result files (optional, defaults to {config}_{model}_{timestamp})"
            echo ""
            echo "Examples:"
            echo "  $0 baseline                              # Test baseline with 8B in ./results"
            echo "  $0 production 70B                       # Test production with 70B in ./results"
            echo "  $0 connector --output-dir /custom/path  # Test connector with 8B in custom path"
            echo "  $0 lmcache 8B --output-dir ./test_run   # Test lmcache with 8B in ./test_run"
            echo "  $0 production --prefix my_experiment     # Custom prefix: my_experiment_output_1.csv"
            exit 0
            ;;
        baseline|production|connector|lmcache)
            if [[ -z "$CONFIG" ]]; then
                CONFIG="$1"
            else
                echo "❌ Multiple configurations specified: $CONFIG and $1"
                exit 1
            fi
            shift
            ;;
        8B|70B)
            MODEL_SIZE="$1"
            shift
            ;;
        *)
            echo "❌ Unknown argument: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Validate required parameters
if [[ -z "$CONFIG" ]]; then
  echo "❌ Configuration is required"
  echo ""
  echo "Usage: $0 <config> [model_size] [--output-dir <path>] [--prefix <name>]"
  echo "  config: baseline, production, connector, lmcache"
  echo "  model_size: 8B (default) or 70B"
  echo ""
  echo "Examples:"
  echo "  $0 baseline                              # Test baseline with 8B in ./results"
  echo "  $0 production 70B                       # Test production with 70B in ./results"
  echo "  $0 connector --output-dir /custom/path  # Test connector with 8B in custom path"
  echo "  $0 lmcache 8B --output-dir ./test_run   # Test lmcache with 8B in ./test_run"
  echo "  $0 production --prefix my_experiment     # Custom prefix: my_experiment_output_1.csv"
  exit 1
fi

# Model configurations
if [[ "$MODEL_SIZE" == "8B" ]]; then
  MODEL="Qwen/Qwen3-8B"
  ISL_VALUES=(6000 8000 16000 32000 64000 128000)
elif [[ "$MODEL_SIZE" == "70B" ]]; then
  MODEL="Qwen/Qwen2.5-72B-Instruct"
  ISL_VALUES=(6000 8000 16000 32000 64000 128000)
else
  echo "Error: Model size must be 8B or 70B"
  exit 1
fi

BASE_URL="http://localhost:8000"

# Benchmark parameters
TARGET_TOTAL_TOKENS=350000 

OUTPUT_LEN=100
REPEAT_COUNT=2
REPEAT_MODE="tile"
CACHE_HIT_MISS_RATIO="5:5"
MAX_INFLIGHT_REQUESTS=1

# Create results directory
mkdir -p "$RESULTS_DIR"

# Check if server is running
if ! curl -s "$BASE_URL/health" >/dev/null 2>&1; then
  echo "❌ vLLM server is not running on $BASE_URL"
  echo "Start the server first: ./start_vllm.sh $CONFIG $MODEL_SIZE"
  exit 1
fi

# Check if benchmark script exists
if [[ ! -f "$BENCHMARK_SCRIPT" ]]; then
  echo "❌ Benchmark script not found: $BENCHMARK_SCRIPT"
  echo "Please ensure the benchmark repo is cloned and the path is correct"
  exit 1
fi

echo "🚀 Running KVBM test with long_doc_qa benchmark"
echo "Configuration: $CONFIG"
echo "Model: $MODEL ($MODEL_SIZE)"
echo "ISL values: ${ISL_VALUES[*]}"
echo "Results will be saved in: $RESULTS_DIR"
echo ""

# Generate prefix for this test run
if [[ -n "$CUSTOM_PREFIX" ]]; then
    FILE_PREFIX="$CUSTOM_PREFIX"
    OUTPUT_PREFIX="${RESULTS_DIR}/${CUSTOM_PREFIX}"
else
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    FILE_PREFIX="${CONFIG}_${MODEL_SIZE}_${TIMESTAMP}"
    OUTPUT_PREFIX="${RESULTS_DIR}/${CONFIG}_${MODEL_SIZE}_${TIMESTAMP}"
fi

echo "Starting benchmark..."
echo "Targeting Total Tokens per Round: $TARGET_TOTAL_TOKENS (Dynamic Num Documents)"
echo ""

# Create summary file
SUMMARY_FILE="${OUTPUT_PREFIX}_summary.csv"
echo "ISL,Num_Docs,Mean_TTFT,Query_Time,Prompt_Count" > "$SUMMARY_FILE"

# Run benchmark for each ISL value
FAILED=0
for isl in "${ISL_VALUES[@]}"; do
  
  # --- DYNAMIC CALCULATION ---
  # Calculate required documents to hit target memory pressure
  # We enforce a minimum of 4 documents to ensure rotation logic works
  CALC_DOCS=$(( TARGET_TOTAL_TOKENS / isl ))
  if [ "$CALC_DOCS" -lt 4 ]; then
    CURRENT_NUM_DOCS=4
  else
    CURRENT_NUM_DOCS=$CALC_DOCS
  fi
  
  echo "====================================="
  echo "Running ISL: ${isl} | Docs: ${CURRENT_NUM_DOCS} | Est. Total Tokens: $(( isl * CURRENT_NUM_DOCS ))"
  echo "====================================="
  
  OUTPUT_FILE="${OUTPUT_PREFIX}_isl_${isl}.log"
  
  if python "$BENCHMARK_SCRIPT" \
    --model "$MODEL" \
    --num-documents "$CURRENT_NUM_DOCS" \
    --document-length "$isl" \
    --output-len "$OUTPUT_LEN" \
    --repeat-count "$REPEAT_COUNT" \
    --repeat-mode "$REPEAT_MODE" \
    --hit-miss-ratio "$CACHE_HIT_MISS_RATIO" \
    --max-inflight-requests "$MAX_INFLIGHT_REQUESTS" \
    2>&1 | tee "$OUTPUT_FILE"; then
    
    echo "✅ ISL ${isl} completed"
    
    # Extract metrics from output and append to summary
    MEAN_TTFT=$(grep "Query round mean TTFT:" "$OUTPUT_FILE" | awk '{print $5}' | sed 's/s//')
    QUERY_TIME=$(grep "Query round time:" "$OUTPUT_FILE" | awk '{print $4}' | sed 's/s//')
    PROMPT_COUNT=$(grep "Query round prompt count:" "$OUTPUT_FILE" | awk '{print $5}')
    
    # Added CURRENT_NUM_DOCS to the CSV output
    echo "${isl},${CURRENT_NUM_DOCS},${MEAN_TTFT},${QUERY_TIME},${PROMPT_COUNT}" >> "$SUMMARY_FILE"
  else
    echo "❌ ISL ${isl} failed"
    FAILED=1
  fi
  
  echo ""
done

echo ""
if [[ $FAILED -eq 0 ]]; then
  echo "✅ All tests completed successfully!"
else
  echo "⚠️  Some tests failed. Check individual log files for details."
fi

echo "Results saved with prefix: ${FILE_PREFIX}"
echo ""
echo "Generated files:"
echo "  📄 $(basename "$SUMMARY_FILE")"
for isl in "${ISL_VALUES[@]}"; do
    file="${OUTPUT_PREFIX}_isl_${isl}.log"
    if [[ -f "$file" ]]; then
        echo "  📄 $(basename "$file")"
    fi
done
echo ""
echo "Summary results:"
column -t -s',' "$SUMMARY_FILE"

exit $FAILED
