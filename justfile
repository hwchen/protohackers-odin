run problem:
    odin run {{problem}}

upload problem:
    odin build {{problem}} -o:speed && \
    scp {{problem}}.bin protohackers:~/protohackers/.
