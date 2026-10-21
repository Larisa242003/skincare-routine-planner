import express from 'express';
import cors from 'cors';
import { authRouter } from './modules/auth/auth.routes.js';
import { errorHandler } from './middleware/errorHandler.js';
import { usersRouter } from './modules/users/users.routes.js';

export const app = express();

app.disable('x-powered-by');
app.use(cors());
app.use(express.json());

app.get('/health', (_req, res) => {
  res.json({ ok: true });
});

app.use('/api/v1/auth', authRouter);
app.use('/api/v1/me', usersRouter);

app.use(errorHandler);