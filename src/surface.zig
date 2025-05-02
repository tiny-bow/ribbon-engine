const rgl = @import("rgl");
const assets = @import("assets");

pub const ShaderProgram = struct {
    gpu: ?rgl.Program = null,
    vert: ?assets.AssetRef(Shader) = null,
    frag: ?assets.AssetRef(Shader) = null,

    pub const asset_type = assets.AssetType {
        .name = "shader_program",
        .vtable = &struct {
            pub const vtable = assets.AssetType.VTable {
                .analyze = assets.AssetType.VTable.Analyzer.autoToml(ShaderProgram, "shader_program"),
            };
        }.vtable,
    };
};

pub const Shader = struct {
    gpu: ?rgl.Shader,
    src: assets.LazyBytes,

    pub const asset_type = assets.AssetType {
        .name = "shader",
        .vtable = &struct {
            pub const vtable = assets.AssetType.VTable {
                .analyze = .none,
            };
        }.vtable,
    };
};


pub const Image = struct {
    src: assets.LazyBytes,

    pub const asset_type = assets.AssetType {
        .name = "image",
        .vtable = &struct {
            pub const vtable = assets.AssetType.VTable {
                .analyze = .none,
            };
        }.vtable,
    };
};

pub const Texture = struct {
    gpu: ?rgl.Texture,
    img: assets.AssetRef(Image),

    pub const asset_type = assets.AssetType {
        .name = "texture",
        .vtable = &struct {
            pub const vtable = assets.AssetType.VTable {
                .analyze = assets.AssetType.VTable.Analyzer.autoToml(Texture, "texture"),
            };
        }.vtable,
    };
};
