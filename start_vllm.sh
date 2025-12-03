#!/bin/bash

# Enhanced vLLM starter script with Compute Sanitizer support
# Usage: ./start_vllm.sh <config> [model_size] [profile=true] [sanitize=true]
# config: baseline, production, connector, lmcache
# model_size: 8B (default) or 70B
# profile=true: enable nsys profiling (optional)
# sanitize=true: enable compute-sanitizer (optional)

set -e

CONFIG=$1
MODEL_SIZE=${2:-"8B"}

# Parse named parameters
ENABLE_PROFILE="false"
ENABLE_SANITIZER="false"
SANITIZER_TOOL="memcheck"  # Default tool
# SANITIZER_OPTIONS="--leak-check=full --track-origins=yes" # ❌ Remove this line

for arg in "$@"; do
    case $arg in
        profile=true)
            ENABLE_PROFILE="true"
            shift
            ;;
        profile=false)
            ENABLE_PROFILE="false"
            shift
            ;;
        sanitize=true)
            ENABLE_SANITIZER="true"
            shift
            ;;
        sanitize=false)
            ENABLE_SANITIZER="false"
            shift
            ;;
        sanitize=memcheck)
            ENABLE_SANITIZER="true"
            SANITIZER_TOOL="memcheck"
            shift
            ;;
        sanitize=racecheck)
            ENABLE_SANITIZER="true"
            SANITIZER_TOOL="racecheck"
            shift
            ;;
        sanitize=initcheck)
            ENABLE_SANITIZER="true"
            SANITIZER_TOOL="initcheck"
            shift
            ;;
    esac
done

# Parse eager parameter
ENFORCE_EAGER=""
for arg in "$@"; do
    case $arg in
        eager=true)
            ENFORCE_EAGER="--enforce-eager"
            shift
            ;;
        eager=false)
            ENFORCE_EAGER=""
            shift
            ;;
    esac
done

if [[ -z "$CONFIG" ]]; then
   echo "Usage: $0 <config> [model_size] [profile=true] [sanitize=true]"
   echo "  config: baseline, production, connector, lmcache"
   echo "  model_size: 8B (default) or 70B"
   echo "  profile=true: enable nsys profiling (optional)"
   echo "  sanitize=true: enable compute-sanitizer (optional)"
   echo "  sanitize=memcheck: enable memory checking (default)"
   echo "  sanitize=racecheck: enable race condition checking"
   echo "  sanitize=initcheck: enable initialization checking"
   echo ""
   echo "Examples:"
   echo "  $0 baseline                                    # Start baseline config"
   echo "  $0 production                                  # Start production config"
   echo "  $0 connector 70B                              # Start connector config with 70B model"
   echo "  $0 baseline profile=true                      # Start baseline with profiling"
   echo "  $0 connector sanitize=true                    # Start connector with memory checking"
   echo "  $0 connector sanitize=racecheck               # Start connector with race checking"
   echo "  $0 connector 70B profile=true sanitize=true   # Start connector 70B with both profiling and sanitizing"
   exit 1
fi

# Model configurations
if [[ "$MODEL_SIZE" == "8B" ]]; then
   MODEL="Qwen/Qwen3-8B"
   TP=1
elif [[ "$MODEL_SIZE" == "70B" ]]; then
   MODEL="Qwen/Qwen2.5-72B-Instruct"
   TP=4
else
   echo "Error: Model size must be 8B or 70B"
   exit 1
fi

PORT=8000

# Stop any existing vLLM process
echo "Stopping any existing vLLM processes..."
pkill -f "vllm serve" || true
sleep 3

# Build vLLM command based on configuration
case $CONFIG in
   "baseline")
       echo "Starting BASELINE configuration (no prefix caching, no connector)"
       CMD="vllm serve $ENFORCE_EAGER --port $PORT --gpu-memory-utilization 0.8 --rope-scaling '{\"rope_type\":\"yarn\",\"factor\":4.0,\"original_max_position_embeddings\":32768}' --max-model-len 131072 --disable-log-requests"
       ;;
  
   "production")
       echo "Starting PRODUCTION configuration (prefix caching + connector)"
       CMD="DYN_KVBM_CPU_CACHE_GB=100 DYN_KVBM_DISK_CACHE_GB=50 DYN_KVBM_LEADER_WORKER_INIT_TIMEOUT_SECS=1200 VLLM_SERVER_DEV_MODE=1 RUST_BACKTRACE=1 vllm serve $ENFORCE_EAGER --disable-log-requests --port $PORT --gpu-memory-utilization 0.80 --rope-scaling '{\"rope_type\":\"yarn\",\"factor\":4.0,\"original_max_position_embeddings\":32768}' --max-model-len 131072 --kv-transfer-config '{\"kv_connector\":\"DynamoConnector\",\"kv_role\":\"kv_both\", \"kv_connector_module_path\": \"kvbm.vllm_integration.connector\"}'"
       ;;
  
   "connector")
       echo "Starting CONNECTOR configuration (no prefix caching, connector only)"
       CMD="DYN_KVBM_CPU_CACHE_GB=100 DYN_KVBM_LEADER_WORKER_INIT_TIMEOUT_SECS=1200 RUST_BACKTRACE=1 DYN_LOG=info,_core::llm::block_manager::vllm::connector::worker=error,dynamo_llm::block_manager::block=error vllm serve $ENFORCE_EAGER --port $PORT --gpu-memory-utilization 0.80 --rope-scaling '{\"rope_type\":\"yarn\",\"factor\":4.0,\"original_max_position_embeddings\":32768}' --max-model-len 131072 --disable-log-requests --no-enable-prefix-caching --kv-transfer-config '{\"kv_connector\":\"DynamoConnector\",\"kv_role\":\"kv_both\", \"kv_connector_module_path\": \"kvbm.vllm_integration.connector\"}'"
       ;;

   "lmcache")
       echo "Starting LMCACHE configuration (LMCache connector)"
       CMD="LMCACHE_CHUNK_SIZE=256 LMCACHE_LOCAL_CPU=True LMCACHE_MAX_LOCAL_CPU_SIZE=100 LMCACHE_USE_EXPERIMENTAL=True vllm serve $ENFORCE_EAGER --port $PORT --gpu-memory-utilization 0.80 --disable-log-requests --kv-transfer-config '{\"kv_connector\":\"LMCacheConnectorV1\",\"kv_role\":\"kv_both\",\"kv_connector_extra_config\": {}}'"
       ;;

    "trtllm")
       echo "Starting TRTLLM configuration (TRTLLM connector)"
       CMD="DYN_LOG=debug DYN_KVBM_CPU_CACHE_GB=3 DYN_KVBM_DISK_CACHE_GB=100 DYN_KVBM_LEADER_WORKER_INIT_TIMEOUT_SECS=1200 VLLM_SERVER_DEV_MODE=1 RUST_BACKTRACE=1 trtllm-serve --host localhost --port $PORT --max_seq_len 32000 --max_num_tokens 32000 --extra_llm_api_options /tmp/kvbm_llm_api_config.yaml"
       ;;
  
   *)
       echo "Error: Unknown configuration '$CONFIG'"
       echo "Valid configurations: baseline, production, connector, lmcache"
       exit 1
       ;;
esac

# Add tensor parallel for 70B
if [[ "$TP" -gt 1 ]]; then
   CMD="$CMD --tensor-parallel-size $TP"
fi

# Add model
CMD="$CMD $MODEL"

# Setup Compute Sanitizer if enabled
if [[ "$ENABLE_SANITIZER" == "true" ]]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    SANITIZER_OUTPUT="/results/${CONFIG}/compute_sanitizer_${CONFIG}_${MODEL_SIZE}_${SANITIZER_TOOL}_${TIMESTAMP}.log"
    
    # Create the output directory if it doesn't exist
    mkdir -p "/results/${CONFIG}"
    
    echo "🔍 Compute Sanitizer enabled - output will be saved to: $SANITIZER_OUTPUT"
    echo "🛠️  Sanitizer tool: $SANITIZER_TOOL"
    
    # Build compute-sanitizer command with ONLY VALID options
    SANITIZER_CMD="compute-sanitizer"
    SANITIZER_CMD="$SANITIZER_CMD --tool=$SANITIZER_TOOL"
    SANITIZER_CMD="$SANITIZER_CMD --log-file=$SANITIZER_OUTPUT"
    # Remove --force-gpu-init (not valid)
    
    # Add tool-specific options (ONLY VALID ONES)
    case $SANITIZER_TOOL in
        "memcheck")
            SANITIZER_CMD="$SANITIZER_CMD --leak-check=full"
            SANITIZER_CMD="$SANITIZER_CMD --check-api-memory-access=yes"
            ;;
        "racecheck")
            SANITIZER_CMD="$SANITIZER_CMD --racecheck-report=all"
            ;;
        "initcheck")
            # No additional options needed for initcheck
            ;;
    esac
    
    CMD="$SANITIZER_CMD env $CMD"
    
    echo "📊 Compute Sanitizer configuration:"
    echo "  Tool: $SANITIZER_TOOL"
    echo "  Output file: $SANITIZER_OUTPUT"
    echo "  Command: $SANITIZER_CMD"
    echo ""
fi

# Setup profiling if enabled
if [[ "$ENABLE_PROFILE" == "true" ]]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    PROFILE_OUTPUT="/results/${CONFIG}/nsys_${CONFIG}_${MODEL_SIZE}_${TIMESTAMP}.qdrep"
    
    # Create the output directory if it doesn't exist
    mkdir -p "/results/${CONFIG}"
    
    echo "🔍 Profiling enabled - output will be saved to: $PROFILE_OUTPUT"
    
    # Wrap command with nsys
    NSYS_CMD="nsys profile"
    NSYS_CMD="$NSYS_CMD --output=$PROFILE_OUTPUT"
    NSYS_CMD="$NSYS_CMD --force-overwrite=true"
    NSYS_CMD="$NSYS_CMD --trace=cuda,nvtx,osrt"
    NSYS_CMD="$NSYS_CMD --export=sqlite"
    NSYS_CMD="$NSYS_CMD --gpuctxsw=true"
    
    CMD="$NSYS_CMD env $CMD"
    
    echo "📊 Nsys profiling configuration:"
    echo "  Output file: $PROFILE_OUTPUT"
    echo "  Traces: CUDA, NVTX, OS Runtime"
    echo "  Capture range: CUDA Profiler API"
    echo "  Export format: SQLite"
    echo ""
fi

# Trap Ctrl+C (SIGINT) and cleanup
trap "echo Exiting...; exit" SIGINT SIGTERM

echo "Model: $MODEL (TP=$TP)"
echo "Configuration: $CONFIG"
echo "Port: $PORT"
if [[ "$ENABLE_PROFILE" == "true" ]]; then
    echo "Profiling: ENABLED"
else
    echo "Profiling: DISABLED"
fi
if [[ "$ENABLE_SANITIZER" == "true" ]]; then
    echo "Compute Sanitizer: ENABLED ($SANITIZER_TOOL)"
else
    echo "Compute Sanitizer: DISABLED"
fi
echo ""
echo "Starting server in foreground..."
echo "Command: $CMD"
echo ""
echo "📝 Press Ctrl+C to stop the server"
if [[ "$ENABLE_PROFILE" == "true" ]]; then
    echo "🔍 Profiling data will be saved when server stops"
fi
if [[ "$ENABLE_SANITIZER" == "true" ]]; then
    echo "🛠️  Compute Sanitizer output will be saved when server stops"
fi
echo "=================================="
echo ""

# Execute command directly in foreground
exec bash -c "$CMD" 2>&1 | tee "/results/vllm_${CONFIG}_${MODEL_SIZE}_$(date +%Y%m%d_%H%M%S).log"
