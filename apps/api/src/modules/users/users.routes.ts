import { Router } from 'express';
import { prisma } from '../../lib/prisma.js';
import { requireAuth } from '../../middleware/auth.js';
import { HttpError } from '../../utils/httpError.js';

export const usersRouter = Router();

usersRouter.get('/', requireAuth, async (req, res) => {
  const user = await prisma.users.findUnique({
    where: { id: req.user!.id },
    select: {
      id: true,
      email: true,
      role: true,
      skin_type: true,
      concerns: true,
      morning_at: true,
      evening_at: true,
      created_at: true,
    },
  });
  if (!user) throw new HttpError(404, 'NOT_FOUND', 'User not found');
  res.json({ user });
});