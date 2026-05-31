import mongoose from 'mongoose';

const userSchema = new mongoose.Schema(
  {
    // The core credentials
    username: {
      type: String,
      required: [true, 'Username is required'],
      unique: true,
      trim: true,
      lowercase: true,
    },
    name: {
      type: String,
      required: [true, 'Name is required'],
      trim: true,
    },
    email: {
      type: String,
      required: [true, 'Email is required'],
      unique: true,
      trim: true,
      lowercase: true,
    },
    password_hash: {
      type: String,
      required: [true, 'Password hash is required'],
    },

    // Security tracking metadata
    registration_ip: {
      type: String,
      default: null,
    },
    registration_user_agent: {
      type: String,
      default: null,
    },

    // Account status controls
    email_verified: {
      type: Boolean,
      default: false,
    },
    account_status: {
      type: String,
      enum: ['active', 'suspended', 'pending'],
      default: 'active',
    },
  },
  {
    // This automatically creates and updates 'created_at' and 'updated_at'
    timestamps: { createdAt: 'created_at', updatedAt: 'updated_at' },
  }
);

const User = mongoose.model('User', userSchema);
export default User;
