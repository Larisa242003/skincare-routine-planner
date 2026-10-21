import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';
import { prisma } from '../../lib/prisma.js';
import { env } from '../../config/env.js';
import { HttpError } from '../../utils/httpError.js';

const publicUser = { id: true, email: true, role: true, created_at: true } as const;

// Used so a login for an unknown email takes as long as a real one.
const DUMMY_HASH = bcrypt.hashSync('not-a-real-password', 12);

function signToken(user: { id: string; role: string }) {
  return jwt.sign({ role: user.role }, env.JWT_SECRET, {
    subject: user.id,
    expiresIn: '7d',
  });
}

export async function register(email: string, password: string) {
  const existing = await prisma.users.findFirst({ where: { email }, select: { id: true } });
  if (existing) {
    throw new HttpError(409, 'EMAIL_TAKEN', 'An account with this email already exists');
  }

  const password_hash = await bcrypt.hash(password, 12);

  try {
    const user = await prisma.users.create({
      data: { email, password_hash },
      select: publicUser,
    });
    return { user, token: signToken(user) };
  } catch (err: any) {
    if (err?.code === 'P2002') {
      throw new HttpError(409, 'EMAIL_TAKEN', 'An account with this email already exists');
    }
    throw err;
  }
}

export async function login(email: string, password: string) {
  const user = await prisma.users.findFirst({
    where: { email },
    select: { ...publicUser, password_hash: true },
  });

  const passwordOk = await bcrypt.compare(password, user?.password_hash ?? DUMMY_HASH);
  if (!user || !passwordOk) {
    throw new HttpError(401, 'INVALID_CREDENTIALS', 'Email or password is incorrect');
  }

  const safeUser = { id: user.id, email: user.email, role: user.role, created_at: user.created_at };
  return { user: safeUser, token: signToken(user) };
}