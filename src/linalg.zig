/// 2-component standard-precision floating-point vector.
pub const V2f = @Vector(2, f32);
/// 2-component double-precision floating-point vector.
pub const V2d = @Vector(2, f64);
/// 2-component signed integer vector.
pub const V2i = @Vector(2, i32);
/// 2-component unsigned integer vector.
pub const V2u = @Vector(2, u32);
/// 3-component standard-precision floating-point vector.
pub const V3f = @Vector(3, f32);
/// 3-component double-precision floating-point vector.
pub const V3d = @Vector(3, f64);
/// 3-component signed integer vector.
pub const V3i = @Vector(3, i32);
/// 3-component unsigned integer vector.
pub const V3u = @Vector(3, u32);
/// 4-component standard-precision floating-point vector.
pub const V4f = @Vector(4, f32);
/// 4-component double-precision floating-point vector.
pub const V4d = @Vector(4, f64);
/// 4-component signed integer vector.
pub const V4i = @Vector(4, i32);
/// 4-component unsigned integer vector.
pub const V4u = @Vector(4, u32);
/// 3x3 matrix of standard-precision floating-point vectors.
pub const Matrix3 = [3]V3f;
/// 4x4 matrix of standard-precision floating-point vectors.
pub const Matrix4 = [4]V4f;
