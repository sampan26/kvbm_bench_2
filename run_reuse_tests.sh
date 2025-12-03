#!/bin/bash

# Test runner for KVBM cache reuse rate profitability analysis
# Tests TTFT performance across cache reuse rates from 10% to 90%
# Usage: ./run_test.sh <config> [model_size] [--output-dir <path>] [--prefix <n>]
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
            echo "Usage: $0 <config> [model_size] [--output-dir <path>] [--prefix <n>]"
            echo ""
            echo "Arguments:"
            echo "  config       Configuration to test: baseline, production, connector, lmcache"
            echo "  model_size   Model size: 8B (default) or 70B"
            echo "  --output-dir Directory to save results (optional, defaults to ./results)"
            echo "  --prefix     Custom prefix for result files (optional, defaults to {config}_{model}_{timestamp})"
            echo ""
            echo "This script tests TTFT performance across cache reuse rates from 10% to 90%"
            echo "with fixed ISL of 32K to identify minimum profitable reuse rates."
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
  echo "Usage: $0 <config> [model_size] [--output-dir <path>] [--prefix <n>]"
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
elif [[ "$MODEL_SIZE" == "70B" ]]; then
  MODEL="meta-llama/Llama-3.1-70B"
else
  echo "Error: Model size must be 8B or 70B"
  exit 1
fi

BASE_URL="http://localhost:8000"

# Cache reuse rates to test (10% to 90%)
declare -A REUSE_RATES
REUSE_RATES=(
  ["10"]="1:9"
  ["20"]="2:8"
  ["30"]="3:7"
  ["40"]="4:6"
  ["50"]="5:5"
  ["60"]="6:4"
  ["70"]="7:3"
  ["80"]="8:2"
  ["90"]="9:1"
)
DOCUMENT_LENGTH=64000  # Fixed 32K ISL
OUTPUT_LEN=100         # Consistent generation phase
REPEAT_COUNT=2         # Enough iterations to show reuse pattern

# CHANGED: Increased from 20 to 40 to force offloading (Total ~1.28M tokens > 850k Capacity)
NUM_DOCUMENTS=10       

REPEAT_MODE="tile"     # Predictable reuse pattern
MAX_INFLIGHT_REQUESTS=1  # Isolate single request behavior


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

echo "🚀 Running KVBM Cache Reuse Profitability Analysis"
echo "Configuration: $CONFIG"
echo "Model: $MODEL ($MODEL_SIZE)"
echo "Fixed ISL: ${DOCUMENT_LENGTH} tokens (32K)"
echo "Cache reuse rates: 10%, 20%, 30%, 40%, 50%, 60%, 70%, 80%, 90%"
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
echo ""

# Create summary file
SUMMARY_FILE="${OUTPUT_PREFIX}_summary.csv"
echo "Reuse_Rate,Hit_Miss_Ratio,Mean_TTFT,Query_Time,Prompt_Count" > "$SUMMARY_FILE"

# Run benchmark for each cache reuse rate
FAILED=0
FAILED=0
for reuse_pct in 10 20 30 40 50 60 70 80 90; do
  hit_miss_ratio="${REUSE_RATES[$reuse_pct]}"
  
  echo "====================================="
  echo "Testing ${reuse_pct}% cache reuse rate (Ratio: ${hit_miss_ratio})"
  echo "Docs: ${NUM_DOCUMENTS} (Total Context: $(( NUM_DOCUMENTS * DOCUMENT_LENGTH )))"
  echo "====================================="
  
  OUTPUT_FILE="${OUTPUT_PREFIX}_reuse_${reuse_pct}.log"
  
  # NOTE: Removed --max-tokens if it's not in your python script arguments
  # NOTE: Corrected --cache-hit-miss-ratio to --hit-miss-ratio based on previous prompt
  if python "$BENCHMARK_SCRIPT" \
    --model "$MODEL" \
    --num-documents "$NUM_DOCUMENTS" \
    --document-length "$DOCUMENT_LENGTH" \
    --output-len "$OUTPUT_LEN" \
    --repeat-count "$REPEAT_COUNT" \
    --repeat-mode "$REPEAT_MODE" \
    --hit-miss-ratio "$hit_miss_ratio" \
    --max-inflight-requests "$MAX_INFLIGHT_REQUESTS" \
    2>&1 | tee "$OUTPUT_FILE"; then
    
    echo "✅ ${reuse_pct}% reuse rate completed"

    
    # Extract metrics from output and append to summary
    MEAN_TTFT=$(grep "Query round mean TTFT:" "$OUTPUT_FILE" | awk '{print $5}' | sed 's/s//')
    QUERY_TIME=$(grep "Query round time:" "$OUTPUT_FILE" | awk '{print $4}' | sed 's/s//')
    PROMPT_COUNT=$(grep "Query round prompt count:" "$OUTPUT_FILE" | awk '{print $5}')
    
    echo "${reuse_pct},${hit_miss_ratio},${MEAN_TTFT},${QUERY_TIME},${PROMPT_COUNT}" >> "$SUMMARY_FILE"
  else
    echo "❌ ${reuse_pct}% reuse rate failed"
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
for reuse_pct in 10 20 30 40 50 60 70 80 90; do
    file="${OUTPUT_PREFIX}_reuse_${reuse_pct}.log"
    if [[ -f "$file" ]]; then
        echo "  📄 $(basename "$file")"
    fi
done
echo ""
echo "Summary results:"
column -t -s',' "$SUMMARY_FILE"
echo ""
echo "To analyze results, run:"
if [[ -n "$CUSTOM_PREFIX" ]]; then
    echo "  ./analyze_results.sh --folder \"$RESULTS_DIR\" --prefix \"$CUSTOM_PREFIX\""
else
    echo "  ./analyze_results.sh $TIMESTAMP --folder \"$RESULTS_DIR\""
fi

exit $FAILED
