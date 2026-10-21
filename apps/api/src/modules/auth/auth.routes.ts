import { Router } from 'express';
import { validateBody } from '../../middleware/validate.js';
import { registerSchema, loginSchema } from './auth.schemas.js';
import * as authService from './auth.service.js';
import { authLimiter } from '../../middleware/rateLimit.js';

export const authRouter = Router();
authRouter.use(authLimiter);

authRouter.post('/register', validateBody(registerSchema), async (req, res) => {
  const result = await authService.register(req.body.email, req.body.password);
  res.status(201).json(result);
});

authRouter.post('/login', validateBody(loginSchema), async (req, res) => {
  const result = await authService.login(req.body.email, req.body.password);
  res.json(result);
});