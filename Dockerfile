# 1. extracted from rocm-xtra-builder-rocblas
FROM rocm/dev-ubuntu-22.04:5.5.1-complete as rocblas-builder
WORKDIR /src
RUN --mount=type=cache,target=/tmp/cache/download,rw \
    curl -L -o /tmp/cache/download/rocBLAS-5.5.1.tar.gz https://github.com/ROCmSoftwarePlatform/rocBLAS/archive/rocm-5.5.1.tar.gz \
    && tar -xf /tmp/cache/download/rocBLAS-5.5.1.tar.gz -C /src \
    && rm -f /tmp/cache/download/rocBLAS-5.5.1.tar.gz

RUN --mount=type=cache,target=/tmp/cache/download,rw \
    curl -L -o /tmp/cache/download/Tensile-5.5.1.tar.gz https://github.com/ROCmSoftwarePlatform/Tensile/archive/rocm-5.5.1.tar.gz \
    && tar -xvf /tmp/cache/download/Tensile-5.5.1.tar.gz -C /src \
    && rm -f /tmp/cache/download/Tensile-5.5.1.tar.gz
# fix gfx803
RUN rm -rf /src/rocBLAS-rocm-5.5.1/library/src/blas3/Tensile/Logic/asm_full/r9nano*

WORKDIR /src/rocBLAS-rocm-5.5.1

ENV ROCM_PATH=/opt/rocm-5.5.1
ENV ROCM_MAJOR_VERSION=5
ENV ROCM_MINOR_VERSION=5
ENV ROCM_PATCH_VERSION=1
ENV ROCM_LIBPATCH_VERSION=50501
ENV ROCM_PKGTYPE=DEB
ENV CPACK_DEBIAN_PACKAGE_RELEASE=74~22.04

COPY patches /patches
RUN patch -Np1 -d /src/Tensile-rocm-5.5.1 -i /patches/Tensile-fix-fallback-arch-build.patch
RUN patch -Np1 -d /src/rocBLAS-rocm-5.5.1 -i /patches/rocBLAS-configure-but-dont-build.patch

RUN --mount=type=cache,target=/var/cache/apt,rw --mount=type=cache,target=/var/lib/apt,rw \
    apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends cmake \
    && DEBIAN_FRONTEND=noninteractive ./install.sh \
        --cmake_install \
        --dependencies \
        --test_local_path /src/Tensile-rocm-5.5.1 \
        --architecture "gfx803;gfx900;gfx906;gfx908;gfx90a;gfx1010;gfx1030;gfx1100;gfx1101;gfx1102" \
        --logic asm_full \
        --msgpack \
    && rm -rf /var/lib/apt/lists/*

RUN make -C build/release -j$(nproc) TENSILE_LIBRARY_TARGET

# Patch generated rocblas package
FROM rocm/dev-ubuntu-22.04:5.5.1-complete as rocblas-package-builder
WORKDIR /deb

RUN --mount=type=cache,target=/var/cache/apt,rw --mount=type=cache,target=/var/lib/apt,rw \
    apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get download rocblas \
    && rm -rf /var/lib/apt/lists/*

# extract original deb
RUN mkdir extracted && dpkg-deb -R /deb/rocblas_*.deb extracted

# remove broken gfx803 libraries
RUN rm -rf /deb/extracted/opt/rocm-5.5.1/lib/rocblas/library/*gfx803*

# add gfx803 and gfx1010 libraries
COPY --from=rocblas-builder /src/rocBLAS-rocm-5.5.1/build/release/Tensile/library/* /deb/extracted/opt/rocm-5.5.1/lib/rocblas/library/

# overwrite original .deb and delete extracted files
RUN chmod 0755 /deb/extracted/DEBIAN/* \
    && dpkg-deb -Zxz -b extracted /deb/rocblas_*.deb \
    && rm -rf /deb/extracted

# 2. extracted from rocm-xtra-builder-rocsparse
FROM rocm/dev-ubuntu-22.04:5.5.1-complete as rocsparse-builder
# rocSPARSE deps
RUN --mount=type=cache,target=/var/cache/apt,rw --mount=type=cache,target=/var/lib/apt,rw \
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    gfortran \
    make \
    pkg-config \
    libnuma1 \
    cmake \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN --mount=type=cache,target=/tmp/cache/download,rw \
    curl -L -o /tmp/cache/download/rocSPARSE-5.5.1.tar.gz https://github.com/ROCmSoftwarePlatform/rocSPARSE/archive/rocm-5.5.1.tar.gz \
    && tar -xf /tmp/cache/download/rocSPARSE-5.5.1.tar.gz -C /src \
    && rm -f /tmp/cache/download/rocSPARSE-5.5.1.tar.gz

WORKDIR /src/rocSPARSE-rocm-5.5.1

ENV ROCM_PATH=/opt/rocm-5.5.1
ENV ROCM_MAJOR_VERSION=5
ENV ROCM_MINOR_VERSION=5
ENV ROCM_PATCH_VERSION=1
ENV ROCM_LIBPATCH_VERSION=50501
ENV ROCM_PKGTYPE=DEB
ENV CPACK_DEBIAN_PACKAGE_RELEASE=74~22.04

RUN cmake \
    -Wno-dev \
    -B build \
    -S "/src/rocSPARSE-rocm-5.5.1" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=/opt/rocm-5.5.1/bin/hipcc \
    -DCMAKE_CXX_COMPILER=/opt/rocm-5.5.1/bin/hipcc \
    -DCMAKE_INSTALL_PREFIX=/opt/rocm-5.5.1 \
    -DBUILD_FILE_REORG_BACKWARD_COMPATIBILITY=ON \
    -DCPACK_SET_DESTDIR=OFF \
    -DCPACK_PACKAGING_INSTALL_PREFIX=/opt/rocm-5.5.1 \
    -DROCM_PATH="/opt/rocm-5.5.1" \
    -DAMDGPU_TARGETS="gfx803;gfx900;gfx906;gfx908;gfx90a;gfx1010;gfx1030;gfx1100;gfx1101;gfx1102 "

RUN cmake --build build --target package -j$(nproc)

WORKDIR /deb

RUN cp /src/rocSPARSE-rocm-5.5.1/build/*.deb .

# 3. extracted from rocm-xtra-dev
FROM rocm/dev-ubuntu-22.04:5.5.1-complete as rocm-xtra-dev
# apt install utilities
RUN --mount=type=cache,target=/var/cache/apt,rw --mount=type=cache,target=/var/lib/apt,rw \
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    python-is-python3 \
    nano \
    wget \
    && rm -rf /var/lib/apt/lists/*

# replace rocblas with our version
WORKDIR /tmp/rocblas
COPY --from=rocblas-package-builder /deb/*.deb .
RUN dpkg -i /tmp/rocblas/*.deb \
    && rm -f /tmp/rocblas/*.deb

# replace rocsparse with our version
WORKDIR /tmp/rocsparse
COPY --from=rocsparse-package-builder /deb/*.deb .
RUN dpkg -i /tmp/rocsparse/*.deb \
    && rm -f /tmp/rocsparse/*.deb

WORKDIR /app

# 4. extracted from rocm-xtra-pytorch-base
# magma deps
RUN --mount=type=cache,target=/var/cache/apt,rw --mount=type=cache,target=/var/lib/apt,rw \
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    gfortran \
    libopenblas-dev \
    cmake \
    ninja-build \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN --mount=type=cache,target=/tmp/cache/download,rw \
    wget -O /tmp/cache/download/magma-2.7.1.tar.gz https://icl.utk.edu/projectsfiles/magma/downloads/magma-2.7.1.tar.gz \
    && tar -xf /tmp/cache/download/magma-2.7.1.tar.gz -C /src \
    && rm -f /src/magma-2.7.1.tar.gz

WORKDIR /src/magma-2.7.1

RUN cmake \
    -B build \
    -G Ninja \
    -DCMAKE_CXX_COMPILER=/opt/rocm/bin/hipcc \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DBUILD_SHARED_LIBS=ON \
    -DMAGMA_ENABLE_HIP=ON \
    -DBLA_VENDOR=OpenBLAS \
    -DGPU_TARGET="gfx803 gfx900 gfx906 gfx908 gfx90a gfx1010 gfx1030 gfx1100 gfx1101 gfx1102"

RUN cmake --build build --target lib sparse-lib

RUN cmake --install build

# 5. extracted from rocm-xtra-pytorch-builder
WORKDIR /git

# pytorch deps
RUN --mount=type=cache,target=/var/cache/apt,rw --mount=type=cache,target=/var/lib/apt,rw \
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    python3-dev \
    && rm -rf /var/lib/apt/lists/*

# pytorch build env vars
ENV ROCM_PATH=/opt/rocm
ENV PYTORCH_ROCM_ARCH="gfx803;gfx900;gfx906;gfx908;gfx90a;gfx1010;gfx1030;gfx1100;gfx1101;gfx1102"
ENV PYTORCH_BUILD_VERSION=2.0.1
ENV PYTORCH_BUILD_NUMBER=1

# prepare torch build
## torch deps
RUN pip install astunparse numpy ninja pyyaml setuptools cmake cffi typing_extensions future six requests dataclasses

RUN git clone --depth 1 --branch v2.0.1 --recursive https://github.com/pytorch/pytorch.git

WORKDIR /git

# setup build dir
RUN mkdir -p /build

# build torch
ENV HIPCC_COMPILE_FLAGS_APPEND="-parallel-jobs=$(nproc)"
ENV HIPCC_LINK_FLAGS_APPEND="-parallel-jobs=$(nproc)"

WORKDIR /git/pytorch
RUN python tools/amd_build/build_amd.py
RUN python setup.py bdist_wheel
RUN cp /git/pytorch/dist/*.whl /build

# Build torchvision
## install torch
RUN pip install --no-cache-dir /git/pytorch/dist/torch-*.whl

# prepare torchvision build
# torchvision deps
RUN --mount=type=cache,target=/var/cache/apt,rw --mount=type=cache,target=/var/lib/apt,rw \
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libpng-dev \
    libjpeg-turbo8-dev \
    ffmpeg \
    libavcodec-dev \
    libswscale-dev \
    libavutil-dev \
    libswresample-dev \
    libavformat-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /git
RUN git clone --depth 1 --branch v0.15.2 --recursive https://github.com/pytorch/vision.git

RUN mkdir /patches
COPY patches /patches

# https://github.com/pytorch/vision/issues/7561
RUN patch -Np1 -d /git/vision -i /patches/torchvision-fix_ROCm_build.patch

## generate wheel
WORKDIR /git/vision

# fix bin/hipcc not found, because ROCM_HOME is lost
# https://github.com/pytorch/vision/issues/6707#issuecomment-1269640873
ENV ROCM_HOME=/opt/rocm-5.5.1

RUN TORCHVISION_USE_NVJPEG=0 \
    TORCHVISION_USE_VIDEO_CODEC=0 \
    TORCHVISION_USE_FFMPEG=1 \
    python setup.py bdist_wheel
RUN cp /git/vision/dist/*.whl /build

# Build torchaudio
ENV USE_FFMPEG=1

# prepare torchaudio build
WORKDIR /git
RUN git clone --depth 1 --branch v2.0.2 --recursive https://github.com/pytorch/audio.git

# torchaudio deps
RUN --mount=type=cache,target=/var/cache/apt,rw --mount=type=cache,target=/var/lib/apt,rw \
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    pkg-config \
    ninja-build \
    libavfilter-dev \
    libavdevice-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /git/audio
RUN CMAKE_PREFIX_PATH=/opt/rocm-5.5.1 BUILD_SOX=1 USE_ROCM=1 python setup.py bdist_wheel
RUN cp /git/audio/dist/*.whl /build

WORKDIR /build

# 6. extracted from rocm-xtra-pytorch
COPY --from=rocm-xtra-pytorch-builder /build/*.whl /tmp/pytorch/

# install pytorch
RUN pip install --no-cache-dir /tmp/pytorch/torch-*.whl

# install torchvision
RUN pip install --no-cache-dir /tmp/pytorch/torchvision-*.whl

# install torchaudio
RUN pip install --no-cache-dir /tmp/pytorch/torchaudio-*.whl

RUN rm -f /tmp/pytorch/*.whl

# install opencv
RUN pip install --no-cache-dir opencv-python==4.8.0.76

# runtime deps (use dev deps to keep it simple)
RUN --mount=type=cache,target=/var/cache/apt,rw --mount=type=cache,target=/var/lib/apt,rw \
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libpng-dev \
    libjpeg-turbo8-dev \
    ffmpeg \
    libavcodec-dev \
    libswscale-dev \
    libavutil-dev \
    libswresample-dev \
    libavformat-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
#FROM ulyssesrr/rocm-xtra-pytorch:rocm5.5.1_ubuntu22.04_pytorch2.0.1 as rocm-xtra-stable-diffusion-webui

RUN --mount=type=cache,target=/var/cache/apt,rw --mount=type=cache,target=/var/lib/apt,rw \
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    python3-venv \
    libpng16-16 \
    libjpeg-turbo8 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /

ARG repo_url=https://github.com/AUTOMATIC1111/stable-diffusion-webui.git

RUN git clone --depth 1 -b "v1.6.0" $repo_url stable-diffusion-webui

WORKDIR /stable-diffusion-webui
    
SHELL ["/bin/bash", "-c"]

RUN python3 -m venv venv --system-site-packages

RUN source venv/bin/activate

RUN pip install -r requirements.txt

COPY ./rocm-xtra-setup.py .

RUN python3 rocm-xtra-setup.py --skip-torch-cuda-test

VOLUME /root/.cache

RUN mkdir -p /stable-diffusion-webui/data
VOLUME /stable-diffusion-webui/data
VOLUME /stable-diffusion-webui/outputs

ENV PYTHONUNBUFFERED=1
EXPOSE 7860

ENTRYPOINT ["python3", "launch.py", "--data-dir", "/stable-diffusion-webui/data", "--listen", "--port", "7860", "--precision", "full", "--no-half", "--medvram", "--enable-insecure-extension-access", "--api"]
CMD ["--opt-sdp-no-mem-attention"]