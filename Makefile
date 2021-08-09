yell: zig-out/bin/yell
	cp "$<" "$@"
	strip "$@"

zig-out/bin/yell: src/main.zig
	zig build -Drelease-fast
