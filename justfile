run problem:
    odin run {{problem}}

upload problem:
    odin build -o:speed && \
    scp {{problem}}.bin protohackers:~/protohackers/.
