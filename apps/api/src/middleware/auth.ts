import type { Request, Response, NextFunction } from 'express';
import jwt from 'jsonwebtoken';
import { prisma } from '../lib/prisma.js';
import { env } from '../config/env.js';
import { HttpError } from '../utils/httpError.js';

export async function requireAuth(req: Request, _res: Response, next: NextFunction) {
  const header = req.headers.authorization;
  if (!header || !header.startsWith('Bearer ')) {
    throw new HttpError(401, 'UNAUTHORIZED', 'Missing or malformed Authorization header');
  }

  const token = header.slice('Bearer '.length);

  let userId: string;
  try {
    const decoded = jwt.verify(token, env.JWT_SECRET);
    if (typeof decoded === 'string' || typeof decoded.sub !== 'string') {
      throw new Error('Bad payload');
    }
    userId = decoded.sub;
  } catch {
    throw new HttpError(401, 'INVALID_TOKEN', 'Token is invalid or expired');
  }

  const user = await prisma.users.findUnique({
    where: { id: userId },
    select: { id: true, role: true },
  });

  if (!user) {
    throw new HttpError(401, 'INVALID_TOKEN', 'User no longer exists');
  }

  req.user = user;
  next();
}

export function requireRole(role: 'admin') {
  return (req: Request, _res: Response, next: NextFunction) => {
    if (req.user?.role !== role) {
      throw new HttpError(403, 'FORBIDDEN', 'You do not have access to this resource');
    }
    next();
  };
}