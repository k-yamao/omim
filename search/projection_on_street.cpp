#include "search/projection_on_street.hpp"

#include "geometry/mercator.hpp"

#include "geometry/robust_orientation.hpp"

#include "base/assert.hpp"


namespace search
{
namespace
{
}  // namespace

// ProjectionOnStreet ------------------------------------------------------------------------------
ProjectionOnStreet::ProjectionOnStreet()
  : m_proj(0, 0), m_distMeters(0), m_segIndex(0), m_projSign(false)
{
}

// ProjectionOnStreetCalculator --------------------------------------------------------------------
ProjectionOnStreetCalculator::ProjectionOnStreetCalculator(vector<m2::PointD> const & points,
                                                           double maxDistMeters)
  : m_points(points), m_maxDistMeters(maxDistMeters)
{
  Init();
}

ProjectionOnStreetCalculator::ProjectionOnStreetCalculator(vector<m2::PointD> && points,
                                                           double maxDistMeters)
  : m_points(move(points)), m_maxDistMeters(maxDistMeters)
{
  Init();
}

bool ProjectionOnStreetCalculator::GetProjection(m2::PointD const & point,
                                                 ProjectionOnStreet & proj) const
{
  size_t const kInvalidIndex = m_segProjs.size();

  m2::PointD bestProj;
  size_t bestIndex = kInvalidIndex;
  double bestDistMeters = numeric_limits<double>::max();

  for (size_t index = 0; index < m_segProjs.size(); ++index)
  {
    m2::PointD proj = m_segProjs[index](point);
    double distMeters = MercatorBounds::DistanceOnEarth(point, proj);
    if (distMeters < bestDistMeters)
    {
      bestProj = proj;
      bestDistMeters = distMeters;
      bestIndex = index;
    }
  }

  if (bestIndex == kInvalidIndex || bestDistMeters > m_maxDistMeters)
    return false;

  proj.m_proj = bestProj;
  proj.m_distMeters = bestDistMeters;
  proj.m_segIndex = bestIndex;
  proj.m_projSign = m2::robust::OrientedS(m_points[bestIndex], m_points[bestIndex + 1], point) <= 0.0;
  return true;
}

void ProjectionOnStreetCalculator::Init()
{
  if (m_points.empty())
    return;

  m_segProjs.resize(m_points.size() - 1);
  for (size_t i = 0; i + 1 != m_points.size(); ++i)
    m_segProjs[i].SetBounds(m_points[i], m_points[i + 1]);
}
}  // namespace search