run problem address_port:
    odin run {{problem}} -- {{address_port}}

# TODO: create protohackers vm, update command to ssh start binary
upload problem:
    odin build {{problem}} -o:speed && \
    scp {{problem}}.bin protohackers:~/protohackers/.
