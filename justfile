run problem:
    odin run {{problem}}

upload problem:
    odin build {{problem}} -o:speed && \
    patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 {{problem}}.bin && \
    scp {{problem}}.bin protohackers:~/protohackers/.
