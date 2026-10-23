"""reexport.aliases: only alias declarations. They emit no code, so the Mojo coverage report omits the file and `:coverage` lists it 0/0."""

comptime Count = Int
comptime LIMIT: Count = 10
comptime Ints = List[
    Count
]
comptime Maybe[T: Movable] = Optional[T]
