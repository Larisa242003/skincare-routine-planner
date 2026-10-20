import { prisma } from './lib/prisma.js';

const groups = await prisma.ingredient_groups.findMany();
console.log(groups);

await prisma.$disconnect();