#include "kernels.h"
#include "cuda.h"
#include <cuda_runtime.h>
#include <cuda_runtime_api.h>
#include <device_functions.h>
#include <device_launch_parameters.h>
#include <device_atomic_functions.h>
#include "math_constants.h"
#include "math_functions.h"
#include "stdio.h"

#define THREADS_PER_BLOCK_DIM 256
#define UNIFORM_GRID_MIN 0.0f
#define UNIFORM_GRID_MAX 2.0f
#define PARTICLE_SIZE 0.05f
#define PARTICLES_PER_CELL 8
#define ELASTICITY 0.0f
#define INERTIA 0.02f
#define GROUND_ELASTICITY 0.5f
#define DAMPING 0.5f

bool first = true;
cudaGraphicsResource* vbo_resource;
int* uniformGrid;
int* particlesInCell;
int gridSize;
float gridWidth;
int cellsPerDim;
float3* velocity;
float3* nextVelocity;

__device__ int3 calculateCell(const float3& position)
{
	float x = position.x;
	float y = position.y;
	float z = position.z;

	int cellX = floor(x / (2*PARTICLE_SIZE));
	int cellY = floor(y / (2*PARTICLE_SIZE));
	int cellZ = floor(z / (2*PARTICLE_SIZE));

	return make_int3(cellX, cellY, cellZ);
}

__global__ void setInitialVelocity_kernel(float3* velocity, int numberParticles)
{
	int i = blockIdx.x * blockDim.x + threadIdx.x;
	if (i < numberParticles) {
		velocity[i].x = 0.0f;
		velocity[i].y = 0.0f;
		velocity[i].z = 0.0f;
	}
}

__global__ void clearGrid_kernel(int* grid, int* particlesInCell, int gridSize)
{
	int x = blockIdx.x*blockDim.x + threadIdx.x;
	if (x < gridSize) {
		particlesInCell[x] = 0;
		for (int i = 0; i < PARTICLES_PER_CELL; ++i)
			grid[x*PARTICLES_PER_CELL + i] = -1;
	}
}

__global__ void updateGrid_kernel(int* grid, const float3* position, size_t numParticles, size_t cellsPerDim, int* particlesInCell)
{
	int i = blockIdx.x*blockDim.x + threadIdx.x;	//index of particle
	if (i < numParticles) {
		int3 cell = calculateCell(position[i]);
		int index = cell.z*cellsPerDim*cellsPerDim*PARTICLES_PER_CELL +
			cell.y*cellsPerDim*PARTICLES_PER_CELL +
			cell.x*PARTICLES_PER_CELL;
		int cellIndex = cell.z*cellsPerDim*cellsPerDim +
			cell.y*cellsPerDim +
			cell.x;
		int offset = atomicAdd(&(particlesInCell[cellIndex]), 1);
		if(offset < PARTICLES_PER_CELL)
			grid[index + offset] = i;
		//printf("Thread:%i, Offset:%i\n", i, offset);
	}
}

__device__ float3 difference(float3 vector1, float3 vector2)
{
	float x = vector1.x - vector2.x;
	float y = vector1.y - vector2.y;
	float z = vector1.z - vector2.z;
	return make_float3(x, y, z);
}

__device__ float3 add(float3 vector1, float3 vector2)
{
	float x = vector1.x + vector2.x;
	float y = vector1.y + vector2.y;
	float z = vector1.z + vector2.z;
	return make_float3(x, y, z);
}

__device__ float3 mult(float scalar, float3 vector)
{
	float x = scalar*vector.x;
	float y = scalar*vector.y;
	float z = scalar*vector.z;
	return make_float3(x, y, z);
}

__device__ float dot(float3 vector1, float3 vector2)
{
	return vector1.x*vector2.x + vector1.y*vector2.y + vector1.z*vector2.z;
}

__device__ float norm(float3 vector)
{
	return sqrt(dot(vector, vector));
}

__device__ float3 cross(float3 vector1, float3 vector2)
{
	float x = vector1.y * vector2.z - vector1.z*vector2.y;
	float y = vector1.z * vector2.x - vector1.x*vector2.z;
	float z = vector1.x * vector2.y - vector1.y*vector2.x;
	return make_float3(x, y, z);
}

//returns velocity of the FIRST particle after collision
__device__ float3 collide(float3 position1, float3 position2, float3 velocity1, float3 velocity2)
{
	//transform into a coordinate system in which particle2 doesn't move
	float3 velTransformed = difference(velocity2, velocity1);
	//project the velocity onto the relative position
	float3 r = difference(position2, position1);
	float len = norm(r);
	float3 r_normed = make_float3(r.x / len, r.y / len, r.z / len);
	float coeff = dot(r_normed, velTransformed);
	float3 velLinear = make_float3(coeff*r_normed.x, coeff*r_normed.y, coeff*r_normed.z);
	float3 velPerpendicular = make_float3(velTransformed.x - velLinear.x, velTransformed.y - velLinear.y, velTransformed.z - velLinear.z);
	float3 newVel = make_float3(ELASTICITY*velTransformed.x + INERTIA*velPerpendicular.x - DAMPING*(2*PARTICLE_SIZE - len)*r_normed.x,
								ELASTICITY*velTransformed.y + INERTIA*velPerpendicular.y - DAMPING*(2*PARTICLE_SIZE - len)*r_normed.y,
								ELASTICITY*velTransformed.z + INERTIA*velPerpendicular.z - DAMPING*(2*PARTICLE_SIZE - len)*r_normed.z
								);
	return newVel;
}

__global__ void collideWithNeighbors_kernel(float3* position, float3* velocity, float3* nextVelocity, int* grid, int cellsPerDim, int numParticles, int* particlesInCell)
{
	int thread = blockIdx.x * blockDim.x + threadIdx.x;
	if (thread < numParticles) {
		float3 pos = position[thread];
		float3 vel = velocity[thread];
		float3 collisionVel = make_float3(0.0f, 0.0f, 0.0f);
		int3 cell = calculateCell(pos);
		for (int xOffset = -1; xOffset < 2; xOffset++) {
			int cellX = cell.x + xOffset;
			if (cellX < 0 || cellX >= cellsPerDim) continue;
			for (int yOffset = -1; yOffset < 2; yOffset++) {
				int cellY = cell.y + yOffset;
				if (cellY < 0 || cellY >= cellsPerDim) continue;
				for (int zOffset = -1; zOffset < 2; zOffset++) {
					int cellZ = cell.z + zOffset;
					if (cellZ < 0 || cellZ >= cellsPerDim) continue;
					int cellIndex = cellZ*cellsPerDim*cellsPerDim + cellY*cellsPerDim + cellX;
					int index = cellZ*cellsPerDim*cellsPerDim*PARTICLES_PER_CELL +
						cellY*cellsPerDim*PARTICLES_PER_CELL
						+ cellX*PARTICLES_PER_CELL;
					for (int particle = 0; particle < particlesInCell[cellIndex]; ++particle) {
						int neighboringParticle = grid[index + particle];
						if (neighboringParticle == -1 || neighboringParticle == thread) continue;
						float3 neighborPos = position[neighboringParticle];
						float3 neighborVel = velocity[neighboringParticle];
						float3 r = difference(neighborPos, pos);
						float distSquared = dot(r, r);
						if (distSquared < (2 * PARTICLE_SIZE)*(2 * PARTICLE_SIZE)) {	//collision detected

							collisionVel = collide(pos, neighborPos, vel, neighborVel);
						}
					}
					
				}
			}
		}
		__syncthreads();

		nextVelocity[thread] = add(vel, collisionVel);
	}
}

__global__ void step(float3* position, float3* velocity, float3* nextVelocity, int numParticles, float3 moon, float dt)
{
	int thread = blockIdx.x*blockDim.x + threadIdx.x;
	if (thread < numParticles) {
		float3 pos = position[thread];
		float3 vel = nextVelocity[thread];
		pos = add(pos, mult(dt, vel));

		//apply gravity
		vel.x += moon.x * 0.001f;
		vel.y += moon.y * 0.001f;
		vel.z += moon.z * 0.001f;
		

		//Collision with boundary
		if (pos.x - PARTICLE_SIZE < UNIFORM_GRID_MIN) {
			pos.x = UNIFORM_GRID_MIN + PARTICLE_SIZE;
			vel.x *= -GROUND_ELASTICITY;
		}
		if (pos.x + PARTICLE_SIZE > UNIFORM_GRID_MAX) {
			pos.x = UNIFORM_GRID_MAX - PARTICLE_SIZE;
			vel.x *= -GROUND_ELASTICITY;
		}

		if (pos.y - PARTICLE_SIZE < UNIFORM_GRID_MIN) {
			pos.y = UNIFORM_GRID_MIN + PARTICLE_SIZE;
			vel.y *= -GROUND_ELASTICITY;
		}
		if (pos.y + PARTICLE_SIZE > UNIFORM_GRID_MAX) {
			pos.y = UNIFORM_GRID_MAX - PARTICLE_SIZE;
			vel.y *= -GROUND_ELASTICITY;
		}

		if (pos.z - PARTICLE_SIZE < UNIFORM_GRID_MIN) {
			pos.z = UNIFORM_GRID_MIN + PARTICLE_SIZE;
			vel.z *= -GROUND_ELASTICITY;
		}
		if (pos.z + PARTICLE_SIZE > UNIFORM_GRID_MAX) {
			pos.z = UNIFORM_GRID_MAX - PARTICLE_SIZE;
			vel.z *= -GROUND_ELASTICITY;
		}

		__syncthreads();

		position[thread] = pos;
		velocity[thread] = vel;
	}
}

// just for calculation of blocks in grid
int iDivUp(int x, int y)
{
	return x / y + (x % y != 0);
}

void simulate(GLuint vbo, size_t numParticles, glm::vec3 moonPosition, float dt)
{
	if (first) {
		cudaGraphicsGLRegisterBuffer(&vbo_resource, vbo, cudaGraphicsRegisterFlagsNone);
		gridWidth = UNIFORM_GRID_MAX - UNIFORM_GRID_MIN;
		cellsPerDim = gridWidth / (2*PARTICLE_SIZE);
		gridSize = cellsPerDim*cellsPerDim*cellsPerDim;
		cudaMalloc(&uniformGrid, gridSize * sizeof(int) * PARTICLES_PER_CELL);
		cudaMalloc(&particlesInCell, gridSize * sizeof(int));
		
		cudaMalloc(&velocity, numParticles * sizeof(float3));
		cudaMalloc(&nextVelocity, numParticles * sizeof(float3));
		dim3 threads_in_block(THREADS_PER_BLOCK_DIM, 1, 1);
		dim3 blocks_in_grid = dim3(iDivUp(numParticles, threads_in_block.x), 1, 1);
		setInitialVelocity_kernel << <blocks_in_grid, threads_in_block >> > (velocity, numParticles);
		first = false;
	}
	float3* positions;
	cudaGraphicsMapResources(1, &vbo_resource, 0);

	size_t N;	//Number of bytes in the position buffer

	cudaGraphicsResourceGetMappedPointer((void**)&positions, &N, vbo_resource);

	dim3 threads_in_block(min(numParticles,THREADS_PER_BLOCK_DIM), 1, 1);

	dim3 blocks_in_grid(iDivUp(gridSize, threads_in_block.x), 1, 1);
	clearGrid_kernel<<<blocks_in_grid, threads_in_block>>>(uniformGrid, particlesInCell, gridSize);
	glm::vec3 center = glm::vec3((UNIFORM_GRID_MAX - UNIFORM_GRID_MIN) / 2, (UNIFORM_GRID_MAX - UNIFORM_GRID_MIN) / 2, (UNIFORM_GRID_MAX - UNIFORM_GRID_MIN) / 2);
	glm::vec3 gravityDirection = glm::normalize(moonPosition - center);
	float3 moon = make_float3(gravityDirection.x, gravityDirection.y, gravityDirection.z);
	blocks_in_grid = dim3(iDivUp(numParticles, threads_in_block.x), 1, 1);

	step << <blocks_in_grid, threads_in_block >> > (positions, velocity, nextVelocity, numParticles, moon, dt);
	updateGrid_kernel << <blocks_in_grid, threads_in_block >> > (uniformGrid, positions, numParticles, cellsPerDim, particlesInCell);
	collideWithNeighbors_kernel << <blocks_in_grid, threads_in_block >> > (positions, velocity, nextVelocity, uniformGrid, cellsPerDim, numParticles, particlesInCell);
	cudaGraphicsUnmapResources(1, &vbo_resource, 0);
}

