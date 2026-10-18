# 1. Base Image
FROM nextcloud:35.0.2-fpm

# 2. Respository setup (Enable non-free for drivers)
RUN sed -i 's/Components: main/Components: main contrib non-free non-free-firmware/g' /etc/apt/sources.list.d/debian.sources

# 3. Install build dependencies and Keyrings for both Debian 11 and 12
RUN apt-get update && apt-get install -y \
    ffmpeg \
    procps \
    intel-media-va-driver-non-free \
    libva-drm2 \
    libva2 \
    vainfo \
    libmagickcore-7.q16-10-extra \
    libimage-exiftool-perl \
    gnupg2 \
    curl \
    && curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/debian11/x86_64/cuda-keyring_1.1-1_all.deb -o cuda-keyring-11.deb \
    && dpkg -i cuda-keyring-11.deb \
    && curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/cuda-keyring_1.1-1_all.deb -o cuda-keyring-12.deb \
    && dpkg -i cuda-keyring-12.deb \
    && echo "deb [trusted=yes] https://developer.download.nvidia.com/compute/cuda/repos/debian11/x86_64/ /" > /etc/apt/sources.list.d/cuda-debian11-x86_64.list \
    && echo "deb [trusted=yes] https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/ /" > /etc/apt/sources.list.d/cuda-debian12-x86_64.list \
    && rm *.deb

# 4. Install Hybird CUDA Environment (11.8 for core, 12 for XLA/MoviNet)
RUN apt-get update && apt-get install -y \
    cuda-libraries-11-8 \
    cuda-nvrtc-11-8 \
    cuda-compiler-11-8 \
    cuda-cudart-11-8 \
    libcudnn8 \
    cuda-libraries-12-6 \
    cuda-nvrtc-12-6 \
    cuda-compiler-12-6 \
    libcudnn9-cuda-12 \
    && rm -rf /var/lib/apt/lists/*

# 5. Merged Environment variables and system library paths
RUN echo "/usr/local/cuda-12.6/targets/x86_64-linux/lib" > /etc/ld.so.conf.d/cuda-12.6.conf \
    && echo "/usr/local/cuda-11.8/targets/x86_64-linux/lib" > /etc/ld.so.conf.d/cuda-11.8.conf \
    && ldconfig

# Explicitly set paths for XLA and CUDA tools
ENV CUDA_HOME=/usr/local/cuda-11.8
ENV PATH="/usr/local/cuda-12.6/bin:/usr/local/cuda-11.8/bin:${PATH}"
ENV LD_LIBRARY_PATH="/usr/local/cuda-11.8/targets/x86_64-linux/lib:/usr/local/cuda-12.6/targets/x86_64-linux/lib:/usr/lib/x86_64-linux-gnu:/usr/local/cuda/lib64:${LD_LIBRARY_PATH}"

# Force TensorFlow to be more generous with platform identification
ENV TF_FORCE_GPU_ALLOW_GROWTH=true

# Plan 2: Bypass XLA registration issues by disabling JIT and specifying CUDA data dir
ENV TF_XLA_FLAGS="--tf_xla_cpu_global_jit=false"
ENV XLA_FLAGS="--xla_gpu_cuda_data_dir=/usr/local/cuda-11.8"

# 6. PHP Configuration Updates
# Make the opcache interned strings buffer configurable from docker-compose.
# Note: this is a silent no-op if upstream ever changes the default value, so
# check the value in the new base image when bumping the Nextcloud tag.
RUN sed -i 's/opcache.interned_strings_buffer=32/opcache.interned_strings_buffer=${PHP_OPCACHE_INTERNED_STRINGS_BUFFER}/g' /usr/local/etc/php/conf.d/opcache-recommended.ini
