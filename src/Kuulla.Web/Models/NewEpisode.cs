namespace Kuulla.Web.Models;

// Web-side mirror of Kuulla.Api.Models.NewEpisode's wire shape.
public record NewEpisode(Episode Episode, bool AutoPlayed);
