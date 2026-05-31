import mongoose from "mongoose";

const userSchema = new mongoose.Schema(
  {
    supabase_user_id: {
      type: String,
      required: true,
      unique: true,
      index: true,
    },

    username: {
      type: String,
      required: true,
      unique: true,
      trim: true,
      lowercase: true,
      minlength: 3,
      maxlength: 30,
    },

    name: {
      type: String,
      required: true,
      trim: true,
      maxlength: 100,
    },

    email: {
      type: String,
      required: true,
      unique: true,
      trim: true,
      lowercase: true,
      index: true,
    },

    avatar_url: {
      type: String,
      default: null,
    },

    bio: {
      type: String,
      default: "",
      maxlength: 500,
    },

    role: {
      type: String,
      enum: ["user", "admin"],
      default: "user",
    },

    email_verified: {
      type: Boolean,
      default: false,
    },

    registration_ip: {
      type: String,
      default: null,
    },

    registration_user_agent: {
      type: String,
      default: null,
    },

    account_status: {
      type: String,
      enum: [
        "active",
        "suspended",
        "pending",
      ],
      default: "active",
    },

    last_login_at: {
      type: Date,
      default: null,
    },
  },
  {
    timestamps: {
      createdAt: "created_at",
      updatedAt: "updated_at",
    },
  }
);

export default mongoose.models.User ||
  mongoose.model("User", userSchema);